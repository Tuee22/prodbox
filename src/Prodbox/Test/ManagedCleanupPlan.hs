{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Compile managed-resource cleanup from the registry entry that owns both
-- the exact capability reference and its interpreter. The resulting action
-- table cannot be redirected independently of the digest committed in the DAG.
module Prodbox.Test.ManagedCleanupPlan
  ( ManagedCleanupEdge (..)
  , CapabilityBoundCleanupAction (..)
  , ManagedCleanupPlan
  , ManagedCleanupPlanError (..)
  , compileManagedCleanupPlan
  , compileCapabilityBoundCleanupPlan
  , managedResourceCleanupAction
  , managedCleanupGraph
  , runManagedCleanupNode
  )
where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.CapabilityKind (CapabilityKind (ManagedDestroy))
import Prodbox.ControlPlane.CapabilityRef (CapabilityRef, refCoordinateDigest)
import Prodbox.ControlPlane.Coordinate (CoordinateDigest (..))
import Prodbox.Lifecycle.ResourceRegistry (ManagedResource (..))
import Prodbox.Lifecycle.TargetCommitIntent (targetValueDigestText)
import Prodbox.Test.CleanupRun
  ( CleanupDependency (..)
  , CleanupDependencyKind
  , CleanupGraph
  , CleanupGraphError
  , CleanupNodeId
  , CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupRunId
  , cleanupNodeCapabilityDigest
  , cleanupNodeId
  , cleanupRunIdText
  , mkCleanupGraph
  , mkCleanupNodeId
  , mkCleanupNodePlan
  , mkCleanupOperationId
  )
import System.Exit (ExitCode (..))

data ManagedCleanupEdge = ManagedCleanupEdge
  { managedCleanupPredecessor :: !String
  , managedCleanupDependencyKind :: !CleanupDependencyKind
  , managedCleanupSuccessor :: !String
  }
  deriving stock (Eq, Show)

data CapabilityBoundCleanupAction = CapabilityBoundCleanupAction
  { capabilityBoundCleanupName :: !String
  , capabilityBoundCleanupRef :: !(CapabilityRef 'ManagedDestroy)
  , executeCapabilityBoundCleanup :: !(FilePath -> IO CleanupNodeOutcome)
  }

data ManagedCleanupPlan = ManagedCleanupPlan
  { managedCleanupGraph :: !CleanupGraph
  , managedCleanupActions :: ![(CleanupNodeId, CapabilityBoundCleanupAction)]
  }

data ManagedCleanupPlanError
  = ManagedCleanupCapabilityInvalid !String !String
  | ManagedCleanupNodeIdInvalid !String !Text
  | ManagedCleanupOperationIdInvalid !String !Text
  | ManagedCleanupEdgeUnknown !String
  | ManagedCleanupGraphInvalid !CleanupGraphError
  deriving stock (Eq, Show)

compileManagedCleanupPlan
  :: CleanupRunId
  -> [ManagedResource]
  -> [ManagedCleanupEdge]
  -> Either ManagedCleanupPlanError ManagedCleanupPlan
compileManagedCleanupPlan runId resources edges = do
  actions <- mapM managedResourceCleanupAction resources
  compileCapabilityBoundCleanupPlan runId actions edges

managedResourceCleanupAction
  :: ManagedResource
  -> Either ManagedCleanupPlanError CapabilityBoundCleanupAction
managedResourceCleanupAction resource = do
  capability <-
    either
      (Left . ManagedCleanupCapabilityInvalid (resourceName resource))
      Right
      (resourceDestroyCapability resource)
  pure
    CapabilityBoundCleanupAction
      { capabilityBoundCleanupName = resourceName resource
      , capabilityBoundCleanupRef = capability
      , executeCapabilityBoundCleanup = \repoRoot -> do
          result <- resourceDestroy resource repoRoot
          pure $ case result of
            ExitSuccess -> CleanupNodeSucceeded
            ExitFailure code -> CleanupNodeFailed ("managed cleanup exited " <> Text.pack (show code))
      }

compileCapabilityBoundCleanupPlan
  :: CleanupRunId
  -> [CapabilityBoundCleanupAction]
  -> [ManagedCleanupEdge]
  -> Either ManagedCleanupPlanError ManagedCleanupPlan
compileCapabilityBoundCleanupPlan runId cleanupActions edges = do
  actions <- mapM compileAction cleanupActions
  dependencies <- mapM compileEdge edges
  let nodes =
        [ mkCleanupNodePlan
            capability
            nodeId
            operationId
            [dependency | (successor, dependency) <- dependencies, successor == nodeId]
        | (nodeId, operationId, capability, _) <- actions
        ]
  graph <- either (Left . ManagedCleanupGraphInvalid) Right (mkCleanupGraph nodes)
  pure
    ManagedCleanupPlan
      { managedCleanupGraph = graph
      , managedCleanupActions = [(nodeId, action) | (nodeId, _, _, action) <- actions]
      }
 where
  compileAction action = do
    nodeId <- nodeIdFor (capabilityBoundCleanupName action)
    operationId <- operationIdFor (capabilityBoundCleanupName action)
    pure (nodeId, operationId, capabilityBoundCleanupRef action, action)
  compileEdge edge = do
    predecessor <- nodeIdFor (managedCleanupPredecessor edge)
    successor <- nodeIdFor (managedCleanupSuccessor edge)
    if any ((== managedCleanupPredecessor edge) . capabilityBoundCleanupName) cleanupActions
      && any ((== managedCleanupSuccessor edge) . capabilityBoundCleanupName) cleanupActions
      then
        Right
          ( successor
          , CleanupDependency predecessor (managedCleanupDependencyKind edge)
          )
      else Left (ManagedCleanupEdgeUnknown (show edge))
  nodeIdFor name =
    either
      (Left . ManagedCleanupNodeIdInvalid name)
      Right
      (mkCleanupNodeId ("managed/" <> Text.pack name))
  operationIdFor name =
    either
      (Left . ManagedCleanupOperationIdInvalid name)
      Right
      (mkCleanupOperationId (cleanupRunIdText runId <> "/managed/" <> Text.pack name))

runManagedCleanupNode
  :: FilePath
  -> ManagedCleanupPlan
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
runManagedCleanupNode repoRoot plan node =
  case find ((== cleanupNodeId node) . fst) (managedCleanupActions plan) of
    Nothing -> pure (CleanupNodeFailed "cleanup node has no managed-resource interpreter")
    Just (_, action)
      | capabilityDigest (capabilityBoundCleanupRef action) /= cleanupNodeCapabilityDigest node ->
          pure (CleanupNodeFailed "cleanup node capability digest differs from its interpreter")
      | otherwise -> executeCapabilityBoundCleanup action repoRoot
 where
  capabilityDigest capability =
    case refCoordinateDigest capability of
      CoordinateDigest digest -> targetValueDigestText digest
