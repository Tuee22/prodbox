{-# LANGUAGE ScopedTypeVariables #-}

-- | Early control removal for a /new test identity/ whose cloud admission is
-- impossible: remove the recorded kind node, node volume and kind network
-- through the retained removal operations, in dependency order, stopping at the
-- first step that is not completely recorded and observed. Each effect keeps
-- its own write-ahead attempt and result record; an independent Docker
-- inventory then checks the result. Foreign, unrecorded or production
-- identities are refused. Host data, the retained root, artifacts and every
-- record stay in place.
module Prodbox.Control.Delete
  ( DeleteStep (..)
  , deleteNewTestIdentity
  ) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeKindName
  , scopeRoot
  )
import Prodbox.Config.KindPlan (KindNodeCreateInput (..))
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoResult (..)
  , DockerNetworkCreateResult (..)
  , DockerNodeContainerCreateResult (..)
  , removeDockerSessionKindNetwork
  , removeDockerSessionNodeVarVolume
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), observeDockerDaemon)
import Prodbox.Control.DockerPeer (DockerPeerResult (..))
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindIntent)
import Prodbox.Control.KindLease
  ( KindOperationOutcome (..)
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkRecoveryObservation (..)
  , kindNetworkDaemon
  , observeRecordedKindNetworkIntent
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkReceiptObservation (..)
  , NetworkTransport (..)
  , observeNetworkReceipt
  )
import Prodbox.Control.KindNetworkRecovery
  ( KindNetworkRemovalAction (..)
  , withNewConnectedKindNetworkRecordedRemoval
  )
import Prodbox.Control.KindNodeBootstrap (writeJournalRecord)
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateRecoveryObservation (..)
  , KindNodeCreateResultObservation (..)
  , KindNodeRemoveControlWrite (..)
  , kindNodeCreateDaemon
  , kindNodeCreateInput
  , observeKindNodeCreateResult
  , observeRecordedKindNodeCreateIntent
  , recordKindNodeRemoveControl
  )
import Prodbox.Control.KindNodeCreateOperation
  ( KindNodeRemoveAction (..)
  , withNewConnectedKindNodeRemove
  )
import Prodbox.Control.KindNodeRemovalSampling
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , nodeRemovalPositive
  , observeNodeRemovalPositiveControl
  )
import Prodbox.Control.KindNodeVolumeOperation
  ( KindNodeVolumeRemovalAction (..)
  , withNewConnectedKindNodeVolumeRemoval
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getSymbolicLinkStatus)

-- | One removal step and what was observed, never a bare success flag.
data DeleteStep = DeleteStep
  { deleteStepName :: !String
  , deleteStepCompleted :: !Bool
  , deleteStepDetail :: !String
  }
  deriving (Eq, Show)

-- | Remove the recorded resources. Steps stop at the first failure and the
-- returned list says which ran. Nothing here proves absence on its own: the
-- caller should read the independent inventory afterwards.
deleteNewTestIdentity :: BootstrapProjection -> IO [DeleteStep]
deleteNewTestIdentity bootstrap
  | scopeEnvironment (bootstrapScope bootstrap) /= Test =
      pure [DeleteStep "scope" False "only a test identity may use early removal"]
  | otherwise = do
      recorded <- observeKindIntent bootstrap
      case recorded of
        KindIntentMatches operation -> do
          node <- removeNode operation
          if not (deleteStepCompleted (last node))
            then pure node
            else do
              volume <- removeVolume operation
              if not (deleteStepCompleted volume)
                then pure (node ++ [volume])
                else do
                  network <- removeNetwork operation
                  pure (node ++ [volume, network])
        other -> pure [DeleteStep "operation" False ("no exactly matching recorded operation: " ++ show other)]
 where
  admit _ _ _ stable = stable
  removeNode operation = do
    known <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
      case proposal of
        NodeCreateRecoveryRecorded intent -> do
          created <- observeKindNodeCreateResult bootstrap intent stable
          pure (Just (intent, created))
        _ -> pure Nothing
    case known of
      KindOperationCallbackReturned
        (Just (intent, NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId)))) -> do
          daemon <- observeDockerDaemon socketOf
          positive <-
            observeNodeRemovalPositiveControl bootstrap (kindNodeCreateDaemon intent) containerId (pure True)
          if daemon /= kindNodeCreateDaemon intent
            then pure [DeleteStep "node" False "the daemon is not the one recorded for this node"]
            else
              if not (nodeRemovalPositive containerId positive)
                then
                  absentDisposition operation (nodeCreateImageId (kindNodeCreateInput intent)) containerId positive
                else do
                  control <-
                    withRecoveredKindOperation bootstrap operation $ \stable ->
                      recordKindNodeRemoveControl bootstrap intent containerId stable
                  case control of
                    KindOperationCallbackReturned NodeRemoveControlRecorded -> do
                      removed <- withNewConnectedKindNodeRemove bootstrap operation admit
                      pure [DeleteStep "node" (nodeRemoved removed) (show removed)]
                    other -> pure [DeleteStep "node" False ("removal control record not written: " ++ show other)]
      KindOperationCallbackReturned (Just (_, NodeCreateResultMissing)) ->
        pure
          [ DeleteStep "node" True "no node create result was recorded, so there is no recorded node to remove"
          ]
      KindOperationCallbackReturned (Just (_, _)) -> do
        -- No result record. With no create attempt record either, the node
        -- effect was never started; an attempt without a result is a lost or
        -- unconfirmed reply and keeps its records for recovery.
        attempted <- recordPresent "kind-node-create-attempt.json"
        pure $
          if attempted == Just False
            then [DeleteStep "node" True "no node create attempt was recorded, so no node effect was started"]
            else
              [ DeleteStep
                  "node"
                  False
                  "a node create attempt exists without a recorded result; records are retained for recovery"
              ]
      KindOperationCallbackReturned Nothing -> do
        -- No node proposal was recoverable. Only an absent intent record (no
        -- node effect was ever planned) is a disposition; a present but
        -- unreadable one keeps its records for recovery.
        planned <- recordPresent "kind-node-create-intent.json"
        attempted <- recordPresent "kind-node-create-attempt.json"
        pure $
          if planned == Just False && attempted == Just False
            then
              [ DeleteStep
                  "node"
                  True
                  "no node create intent was recorded, so no node effect was planned or started"
              ]
            else
              [ DeleteStep
                  "node"
                  False
                  "a node create record exists but its identity is unavailable; records are retained for recovery"
              ]
      other -> pure [DeleteStep "node" False ("recorded node identity unavailable: " ++ show other)]
  -- The recorded node is not listed. That is only a disposition when the
  -- same inventory is shown able to see the field: a never-started control
  -- container made from the recorded image carries a distinct label, must
  -- be listed by that label while the node is not listed by its ID, name or
  -- cluster label, and is removed again before the disposition is recorded.
  absentDisposition operation imageId containerId positive = case positive of
    NodeRemovalReadbackSampled inventory
      | null (nodeRemovalNameIds inventory) && null (nodeRemovalClusterIds inventory) -> do
          let cluster = scopeKindName (bootstrapScope bootstrap)
              label = "io.prodbox.absence-control=" ++ operation
          created <- docker ["create", "--name", cluster ++ "-absence-control", "--label", label, imageId]
          case fmap (takeWhile (/= '\n')) created of
            Just controlId | not (null controlId) -> do
              seen <- docker ["ps", "-a", "--no-trunc", "--filter", "label=" ++ label, "--format", "{{.ID}}"]
              node <- docker ["ps", "-a", "--no-trunc", "--filter", "id=" ++ containerId, "--format", "{{.ID}}"]
              removedControl <- docker ["rm", controlId]
              after <- docker ["ps", "-a", "--no-trunc", "--filter", "label=" ++ label, "--format", "{{.ID}}"]
              let controlWorked = fmap words seen == Just [controlId]
                  nodeAbsent = fmap words node == Just []
                  controlGone = removedControl /= Nothing && fmap words after == Just []
              if controlWorked && nodeAbsent && controlGone
                then do
                  recorded <-
                    writeJournalRecord
                      bootstrap
                      "kind-node-absence-observed.json"
                      ( Aeson.object
                          [ Key.fromString "schema_version" Aeson..= (1 :: Int)
                          , Key.fromString "kind" Aeson..= ("kind-node-absence-observed" :: String)
                          , Key.fromString "operation_id" Aeson..= operation
                          , Key.fromString "container" Aeson..= containerId
                          , Key.fromString "control_container" Aeson..= controlId
                          ]
                      )
                  present <- recordPresent "kind-node-absence-observed.json"
                  let settled = recorded || present == Just True
                  pure
                    [ DeleteStep
                        "node"
                        settled
                        ( if recorded
                            then
                              "the recorded node was not listed while a labelled control container was; absence recorded, not a removal by this command"
                            else
                              if settled
                                then
                                  "absence re-observed with a control container; its record was already written by an earlier delete"
                                else "absence observed but its record was not written"
                        )
                    ]
                else
                  pure
                    [ DeleteStep
                        "node"
                        False
                        ( "absence not established: control listed="
                            ++ show controlWorked
                            ++ ", node absent="
                            ++ show nodeAbsent
                            ++ ", control removed="
                            ++ show controlGone
                        )
                    ]
            _ ->
              pure
                [DeleteStep "node" False "the absence control container could not be created; nothing recorded"]
    _ ->
      pure
        [ DeleteStep
            "node"
            False
            "the independent inventory did not positively list the recorded node, so removal was not attempted"
        ]
  docker arguments = do
    result <-
      captureSubprocessBounded
        (BoundedSubprocessLimits 1 65536 8192 20000000)
        ( Subprocess
            "/usr/bin/docker"
            (["--host", "unix://" ++ socketOf] ++ arguments)
            (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("DOCKER_CONFIG", "/nonexistent")])
            Nothing
        )
    pure $ case result of
      Right output | processExitCode output == ExitSuccess -> Just (processStdout output)
      _ -> Nothing
  nodeRemoved outcome = case outcome of
    KindOperationCallbackReturned
      (DockerPeerCompleted (DockerConnectedInfoCompleted (NodeRemoveActionReturned _ _))) -> True
    _ -> False
  removeVolume operation = do
    planned <- recordPresent "kind-node-var-volume-intent.json"
    if planned == Just False
      then
        pure
          (DeleteStep "volume" True "no volume create intent was recorded, so there is no volume to remove")
      else do
        removedBefore <- recordPresent "kind-node-var-volume-removal-result.json"
        if removedBefore == Just True
          then
            pure (DeleteStep "volume" True "a volume removal result is already recorded for this operation")
          else removeRecordedVolume operation
  removeRecordedVolume operation = do
    removed <-
      withNewConnectedKindNodeVolumeRemoval
        bootstrap
        operation
        (\_ stable -> stable)
        (\session stable -> removeDockerSessionNodeVarVolume session bootstrap operation stable)
    pure (DeleteStep "volume" (volumeRemoved removed) (show removed))
  removeNetwork operation = do
    removedBefore <- recordPresent "kind-network-removal-result.json"
    if removedBefore == Just True
      then
        pure (DeleteStep "network" True "a network removal result is already recorded for this operation")
      else removeRecordedNetwork operation
  removeRecordedNetwork operation = do
    identifier <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      proposal <- observeRecordedKindNetworkIntent bootstrap operation stable
      case proposal of
        NetworkRecoveryRecorded intent -> do
          receipt <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
          pure $ case receipt of
            NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just networkId)))
              | kindNetworkDaemon intent /= DockerDaemonUnobservable -> Just (Right networkId)
            NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply status Nothing))
              | status /= 201 -> Just (Left status)
            _ -> Nothing
        _ -> pure Nothing
    case identifier of
      KindOperationCallbackReturned (Just (Left status)) ->
        pure
          ( DeleteStep
              "network"
              True
              ("the network create was refused with status " ++ show status ++ ", so no network was created")
          )
      KindOperationCallbackReturned (Just (Right networkId)) -> do
        removed <-
          withNewConnectedKindNetworkRecordedRemoval bootstrap operation networkId $ \session stable ->
            removeDockerSessionKindNetwork session networkId stable
        pure (DeleteStep "network" (networkRemoved removed) (show removed))
      other -> pure (DeleteStep "network" False ("recorded network identity unavailable: " ++ show other))
  volumeRemoved outcome = case outcome of
    KindOperationCallbackReturned
      (DockerPeerCompleted (DockerConnectedInfoCompleted (NodeVolumeRemovalActionReturned _ _))) -> True
    _ -> False
  networkRemoved outcome = case outcome of
    KindOperationCallbackReturned
      (DockerPeerCompleted (DockerConnectedInfoCompleted (KindNetworkRemovalReturned _))) -> True
    _ -> False
  socketOf = bootstrapRuntimeSocket bootstrap
  recordPresent name = do
    status <- try (getSymbolicLinkStatus (scopeRoot (bootstrapScope bootstrap) </> name))
    pure $ case status of
      Right _ -> Just True
      Left (failure :: IOException) -> if isDoesNotExistError failure then Just False else Nothing
