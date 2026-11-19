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
  , kindUlaSubnet
  ) where

import Control.Exception (IOException, try)
import Crypto.Hash.SHA1 qualified as SHA1
import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.Text qualified as Text
import Data.Word (Word8)
import Numeric (showHex)
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
  ( FreshScopeResult (..)
  , prepareFreshScope
  , scopeKindName
  )
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), kindNodeRunArguments)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoResult (..)
  , DockerNetworkCreateResult (..)
  , DockerNodeVarCreateResult (..)
  , DockerNodeVarVolumeObservation (..)
  , createDockerSessionKindNetwork
  , createDockerSessionNodeVarVolume
  , loadAndObserveDockerSessionImage
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), observeDockerDaemon)
import Prodbox.Control.DockerPeer (DockerPeerResult (..))
import Prodbox.Control.ImageIdObservation (ImageIdObservation (..))
import Prodbox.Control.KindDockerWorkerPrepare
  ( KindDockerWorkerPreparation (..)
  , prepareKindDockerWorkerPaths
  )
import Prodbox.Control.KindLease
  ( KindOperationOutcome (..)
  , withRecoveredKindOperation
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
  , withNewConnectedKindNetworkRecordedAttempt
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
  , withNewConnectedKindNodeVolumeAttempt
  )
import Prodbox.Control.NodeArchive (VerifiedNodeArchive (..))
import Prodbox.Control.NodeImageOperation (withNewConnectedNodeImageRecordedAttempt)
import Prodbox.Control.Recreate (ArchiveOutcome (..), archiveCompletedOperation)
import Prodbox.Control.Status (observeImageId)
import System.IO (IOMode (ReadMode), withBinaryFile)

type NetworkAttempt =
  KindOperationOutcome
    (DockerPeerResult (DockerConnectedInfoResult (KindNetworkAttemptAction KindNetworkRecordedTransport)))

data ReconcileOutcome
  = ReconcileRootRefused !FreshScopeResult
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
  | ReconcileImageAttempt !String !String
  | ReconcileImageNotObserved !String !String
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

-- | Image, network, then node var volume for one new operation. Each later
-- step runs only after an independent observation of the earlier one; any
-- other outcome is returned and every durable record is retained.
reconcileNewPrerequisites :: BootstrapProjection -> IO ReconcileOutcome
reconcileNewPrerequisites bootstrap = do
  prepared <-
    prepareFreshScope (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
  case prepared of
    FreshScopePrepared -> start
    FreshScopeAlreadyExists -> start
    other -> pure (ReconcileRootRefused other)
 where
  socket = bootstrapRuntimeSocket bootstrap
  start = do
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
    loaded <- withNewConnectedNodeImageRecordedAttempt bootstrap operation $ \verified _ size descriptor session stable -> do
      writeIORef captured (nodeConfigDigest verified)
      loadAndObserveDockerSessionImage session descriptor size (nodeConfigDigest verified) stable
    configDigest <- readIORef captured
    observed <-
      if null configDigest then pure ImageIdUnobservable else observeImageId socket configDigest
    case observed of
      ImageIdObserved {} -> network operation configDigest
      _ -> pure (ReconcileImageNotObserved operation (show loaded))
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
            recorded <- withRecoveredKindOperation bootstrap operation $ \stable ->
              recordKindNetworkIntent bootstrap intent stable
            case recorded of
              KindOperationCallbackReturned NetworkIntentRecorded -> do
                created <- withNewConnectedKindNetworkRecordedAttempt bootstrap operation $ \_ session stable ->
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
        recorded <- withRecoveredKindOperation bootstrap operation $ \stable ->
          recordKindNodeVolumeIntent bootstrap intent stable
        case recorded of
          KindOperationCallbackReturned NodeVolumeIntentRecorded -> do
            created <- withNewConnectedKindNodeVolumeAttempt bootstrap operation $ \session stable ->
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
    daemon <- observeDockerDaemon socket
    let plan = bootstrapKindPlan bootstrap
        input =
          KindNodeCreateInput
            (maybe "" artifactDigest (bootstrapKindTool bootstrap))
            configDigest
            networkId
            (Text.unpack (bootstrapRootGeneration bootstrap))
            operation
            (kindNodeRunArguments plan configDigest)
    case mkKindNodeCreateIntent bootstrap input daemon of
      Nothing -> pure (ReconcileNodeProposalInvalid operation)
      Just intent -> do
        recorded <- withRecoveredKindOperation bootstrap operation $ \stable ->
          recordKindNodeCreateIntent bootstrap intent stable
        case recorded of
          KindOperationCallbackReturned NodeCreateIntentRecorded -> do
            prepared <-
              withRecoveredKindOperation bootstrap operation (prepareKindDockerWorkerPaths bootstrap operation)
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
