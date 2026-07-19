-- | Sprint 5.20: the derived restore/cleanup graph and its total executor.
--
-- The canonical restore cycle was a flat ordered @['Prodbox.TestRestore.RestoreCycleStep']@
-- run by a fail-fast fold: the first failure silently discarded every later
-- step, including chart restorations wholly independent of the failed sibling.
-- This module makes the dependency structure DERIVED DATA (a rule set over
-- chart-dependency and storage-lifetime facts, not authored per site) and
-- replaces the fold with a TOTAL executor that runs every node whose
-- dependencies are satisfiable, records 'NodeBlocked' otherwise, and aggregates
-- every failure into one report — closing the @F-RESTORE@ class of counterexample
-- @LCPC-2026-07-11@ structurally.
--
-- Two edge kinds encode the difference the flat list could not: 'RequiresSuccess'
-- (the dependency must have SUCCEEDED) versus 'RequiresAttempt' (the dependency
-- must merely have been ATTEMPTED). The independent app-chart restorations require
-- only the SUCCESS of the gateway restoration, never the retained-SES node — so a
-- retained-SES failure can never discard them.
module Prodbox.Lifecycle.RestoreGraph
  ( -- * The graph
    RestoreNodeId (..)
  , RestoreEdgeKind (..)
  , RestoreDependency (..)
  , RestoreNode (..)
  , RestoreGraph (..)
  , buildRestoreGraph
  , buildRestoreGraphForPlan
  , restoreCyclePlanRequirement
  , restoreCycleStepNodeId
  , restoreGraphNodeIds

    -- * Pure totality obligations
  , expectedRestoreNodeIds
  , restoreGraphCoverageComplete
  , retainedNodesHaveNoChartLifetimeDependents
  , restoreGraphOrphans

    -- * The total executor
  , RestoreOutcome (..)
  , RestoreNodeResult (..)
  , RestoreReport (..)
  , restoreReportBlocked
  , restoreReportFailed
  , restoreReportSucceeded
  , runRestoreGraphWith
  )
where

import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Prodbox.Lifecycle.StoreLifetime (StoreLifetime (..))
import Prodbox.Substrate (Substrate)
import Prodbox.TestRestore
  ( RestoreChart (..)
  , RestoreCyclePlan (..)
  , RestoreCycleStep (..)
  , RetainedSesRequirement (..)
  )

-- | One node in the restore graph. The chart delete/reconcile nodes mirror the
-- flat 'Prodbox.TestRestore.RestoreCycleStep' actions; the retained-SES
-- preparation is one node.
data RestoreNodeId
  = RestoreNodeDeleteChart !RestoreChart
  | RestoreNodeEnsureGatewayMinioBootstrap
  | RestoreNodeReconcileChart !RestoreChart
  | RestoreNodePrepareRetainedSes
  | RestoreNodeWaitForPublicEdge
  deriving (Eq, Ord, Show)

-- | Whether a dependency must have succeeded, or merely been attempted, before a
-- node may run.
data RestoreEdgeKind
  = RequiresSuccess
  | RequiresAttempt
  deriving (Eq, Ord, Show)

data RestoreDependency = RestoreDependency
  { restoreDependencyOn :: !RestoreNodeId
  , restoreDependencyKind :: !RestoreEdgeKind
  }
  deriving (Eq, Ord, Show)

-- | A node, its derived dependencies, the storage lifetime of the TRANSPORT it
-- writes through, and the strongest storage lifetime of the state it READS. The
-- orphan scan rejects any node that reads retained-or-stronger state through a
-- weaker transport.
data RestoreNode = RestoreNode
  { restoreNodeId :: !RestoreNodeId
  , restoreNodeDependencies :: ![RestoreDependency]
  , restoreNodeTransportLifetime :: !StoreLifetime
  , restoreNodeReadsLifetime :: !StoreLifetime
  }
  deriving (Eq, Show)

data RestoreGraph = RestoreGraph
  { restoreGraphSubstrate :: !Substrate
  , restoreGraphNodes :: ![RestoreNode]
  }
  deriving (Eq, Show)

restoreGraphNodeIds :: RestoreGraph -> [RestoreNodeId]
restoreGraphNodeIds = map restoreNodeId . restoreGraphNodes

-- | The four charts torn down and rebuilt, dependents before the gateway.
restoreChartsToTearDown :: [RestoreChart]
restoreChartsToTearDown =
  [RestoreChartWebsocket, RestoreChartApi, RestoreChartVscode, RestoreChartGateway]

-- | The app charts (everything except the gateway) — reconciled after the
-- gateway restoration, independently of one another and of the retained-SES node.
restoreAppCharts :: [RestoreChart]
restoreAppCharts = [RestoreChartVscode, RestoreChartApi, RestoreChartWebsocket]

requiresSuccessOf :: RestoreNodeId -> RestoreDependency
requiresSuccessOf nodeId = RestoreDependency nodeId RequiresSuccess

requiresAttemptOf :: RestoreNodeId -> RestoreDependency
requiresAttemptOf nodeId = RestoreDependency nodeId RequiresAttempt

-- | Build the derived restore graph. Edges follow a small rule set, never a
-- per-site literal:
--
--   * teardown deletes are mutually independent (no edges);
--   * the gateway/MinIO bootstrap requires every delete to have been ATTEMPTED;
--   * the gateway restoration requires the bootstrap to have SUCCEEDED;
--   * the retained-SES node (a @'ClusterRetained'@ transport) requires the
--     gateway restoration to have SUCCEEDED, and NOTHING chart-lifetime may
--     depend on it (the independence invariant);
--   * each app-chart restoration requires only the gateway restoration's SUCCESS;
--   * the public-edge wait requires every restoration to have been ATTEMPTED.
buildRestoreGraph :: Substrate -> RetainedSesRequirement -> RestoreGraph
buildRestoreGraph substrate requirement =
  RestoreGraph
    { restoreGraphSubstrate = substrate
    , restoreGraphNodes =
        deleteNodes ++ [bootstrapNode, gatewayNode] ++ sesNodes ++ appNodes ++ [waitNode]
    }
 where
  deleteNodes =
    [ RestoreNode
        { restoreNodeId = RestoreNodeDeleteChart chart
        , restoreNodeDependencies = []
        , restoreNodeTransportLifetime = ChartLifetime
        , restoreNodeReadsLifetime = ChartLifetime
        }
    | chart <- restoreChartsToTearDown
    ]

  bootstrapNode =
    RestoreNode
      { restoreNodeId = RestoreNodeEnsureGatewayMinioBootstrap
      , restoreNodeDependencies =
          [requiresAttemptOf (RestoreNodeDeleteChart chart) | chart <- restoreChartsToTearDown]
      , restoreNodeTransportLifetime = ChartLifetime
      , restoreNodeReadsLifetime = ChartLifetime
      }

  gatewayNode =
    RestoreNode
      { restoreNodeId = RestoreNodeReconcileChart RestoreChartGateway
      , restoreNodeDependencies = [requiresSuccessOf RestoreNodeEnsureGatewayMinioBootstrap]
      , restoreNodeTransportLifetime = ChartLifetime
      , restoreNodeReadsLifetime = ChartLifetime
      }

  sesNodes =
    case requirement of
      SesNotRequired -> []
      SesRequired ->
        [ RestoreNode
            { restoreNodeId = RestoreNodePrepareRetainedSes
            , restoreNodeDependencies =
                [requiresSuccessOf (RestoreNodeReconcileChart RestoreChartGateway)]
            , -- The retained-SES transaction reads and writes retained authority
              -- state; its transport must be cluster-retained, never chart-lifetime.
              restoreNodeTransportLifetime = ClusterRetained
            , restoreNodeReadsLifetime = ClusterRetained
            }
        ]

  appNodes =
    [ RestoreNode
        { restoreNodeId = RestoreNodeReconcileChart chart
        , -- The independence fix: an app chart requires ONLY the gateway
          -- restoration's success, never the retained-SES node.
          restoreNodeDependencies =
            [requiresSuccessOf (RestoreNodeReconcileChart RestoreChartGateway)]
        , restoreNodeTransportLifetime = ChartLifetime
        , restoreNodeReadsLifetime = ChartLifetime
        }
    | chart <- restoreAppCharts
    ]

  waitNode =
    RestoreNode
      { restoreNodeId = RestoreNodeWaitForPublicEdge
      , restoreNodeDependencies =
          requiresAttemptOf (RestoreNodeReconcileChart RestoreChartGateway)
            : [requiresAttemptOf (RestoreNodeReconcileChart chart) | chart <- restoreAppCharts]
      , restoreNodeTransportLifetime = ChartLifetime
      , restoreNodeReadsLifetime = ChartLifetime
      }

-- | The 'RetainedSesRequirement' implied by a compiled restore plan: a plan
-- carries the retained-SES preparation step exactly when SES is required. This
-- lets the live wiring derive the graph from the same plan the flat fold
-- consumed, with no second requirement channel to drift.
restoreCyclePlanRequirement :: RestoreCyclePlan -> RetainedSesRequirement
restoreCyclePlanRequirement plan
  | any isPrepare (restoreCycleSteps plan) = SesRequired
  | otherwise = SesNotRequired
 where
  isPrepare (RestorePrepareRetainedSes _) = True
  isPrepare _ = False

-- | The derived restore graph for a compiled 'RestoreCyclePlan'. The graph's
-- node set is a bijection with the plan's step set ('restoreCycleStepNodeId'),
-- proven by the coverage suite, so the live executor's per-node dispatch never
-- misses a step.
buildRestoreGraphForPlan :: RestoreCyclePlan -> RestoreGraph
buildRestoreGraphForPlan plan =
  buildRestoreGraph (restoreCycleSubstrate plan) (restoreCyclePlanRequirement plan)

-- | The graph node id a flat-list 'RestoreCycleStep' maps to. The retained-SES
-- preparation plan payload is dropped: the graph models dependency structure,
-- not the step's execution parameters, which the live executor recovers from the
-- plan step itself.
restoreCycleStepNodeId :: RestoreCycleStep -> RestoreNodeId
restoreCycleStepNodeId step = case step of
  RestoreDeleteChart chart -> RestoreNodeDeleteChart chart
  RestoreEnsureGatewayMinioBootstrap -> RestoreNodeEnsureGatewayMinioBootstrap
  RestoreReconcileChart chart -> RestoreNodeReconcileChart chart
  RestorePrepareRetainedSes _ -> RestoreNodePrepareRetainedSes
  RestoreWaitForPublicEdge -> RestoreNodeWaitForPublicEdge

-- | The node ids the derived graph must contain for a substrate and requirement —
-- the expectation the coverage check compares against, computed independently of
-- 'buildRestoreGraph' so a dropped node is caught.
expectedRestoreNodeIds :: RetainedSesRequirement -> [RestoreNodeId]
expectedRestoreNodeIds requirement =
  [RestoreNodeDeleteChart chart | chart <- restoreChartsToTearDown]
    ++ [RestoreNodeEnsureGatewayMinioBootstrap, RestoreNodeReconcileChart RestoreChartGateway]
    ++ ( case requirement of
           SesNotRequired -> []
           SesRequired -> [RestoreNodePrepareRetainedSes]
       )
    ++ [RestoreNodeReconcileChart chart | chart <- restoreAppCharts]
    ++ [RestoreNodeWaitForPublicEdge]

-- | The node set equals the derived expectation (no node dropped, none extra).
restoreGraphCoverageComplete :: RetainedSesRequirement -> RestoreGraph -> Bool
restoreGraphCoverageComplete requirement graph =
  sort (restoreGraphNodeIds graph) == sort (expectedRestoreNodeIds requirement)

lifetimeRank :: StoreLifetime -> Int
lifetimeRank lifetime = case lifetime of
  ChartLifetime -> 0
  ClusterRetained -> 1
  CrossClusterDurable -> 2

-- | The independence invariant: no chart-lifetime node may @'RequiresSuccess'@ a
-- retained-or-stronger node. Returns the offending (dependent, dependency) pairs;
-- an empty list is the proof that a retained-SES failure cannot discard an
-- independent chart restoration.
retainedNodesHaveNoChartLifetimeDependents :: RestoreGraph -> [(RestoreNodeId, RestoreNodeId)]
retainedNodesHaveNoChartLifetimeDependents graph =
  [ (restoreNodeId node, restoreDependencyOn dependency)
  | node <- restoreGraphNodes graph
  , restoreNodeTransportLifetime node == ChartLifetime
  , dependency <- restoreNodeDependencies node
  , restoreDependencyKind dependency == RequiresSuccess
  , Just target <- [Map.lookup (restoreDependencyOn dependency) lifetimeByNode]
  , lifetimeRank target > lifetimeRank ChartLifetime
  ]
 where
  lifetimeByNode =
    Map.fromList
      [(restoreNodeId node, restoreNodeTransportLifetime node) | node <- restoreGraphNodes graph]

-- | The orphan scan: every node whose transport is weaker than the state it
-- reads. An empty list proves no node reads retained-or-stronger state through a
-- chart-lifetime transport (the @F-RESTORE@/@F-SES@ overlap).
restoreGraphOrphans :: RestoreGraph -> [RestoreNodeId]
restoreGraphOrphans graph =
  [ restoreNodeId node
  | node <- restoreGraphNodes graph
  , lifetimeRank (restoreNodeReadsLifetime node) > lifetimeRank (restoreNodeTransportLifetime node)
  ]

-- | The outcome of running one node.
data RestoreOutcome failure
  = -- | The node ran and succeeded.
    NodeSucceeded
  | -- | The node ran and failed with the interpreter's failure.
    NodeFailed !failure
  | -- | The node did not run because a @'RequiresSuccess'@ dependency did not
    -- succeed (or an @'RequiresAttempt'@ dependency was never reached). Carries
    -- the offending dependency ids.
    NodeBlocked ![RestoreNodeId]
  deriving (Eq, Show)

data RestoreNodeResult failure = RestoreNodeResult
  { restoreResultNode :: !RestoreNodeId
  , restoreResultOutcome :: !(RestoreOutcome failure)
  }
  deriving (Eq, Show)

-- | The aggregate report — every node's outcome, in the executed order. No node
-- is ever silently discarded.
newtype RestoreReport failure = RestoreReport
  { restoreReportResults :: [RestoreNodeResult failure]
  }
  deriving (Eq, Show)

restoreReportSucceeded :: RestoreReport failure -> [RestoreNodeId]
restoreReportSucceeded report =
  [ restoreResultNode result
  | result <- restoreReportResults report
  , isSucceeded (restoreResultOutcome result)
  ]
 where
  isSucceeded NodeSucceeded = True
  isSucceeded _ = False

restoreReportFailed :: RestoreReport failure -> [RestoreNodeId]
restoreReportFailed report =
  [ restoreResultNode result
  | result <- restoreReportResults report
  , isFailed (restoreResultOutcome result)
  ]
 where
  isFailed (NodeFailed _) = True
  isFailed _ = False

restoreReportBlocked :: RestoreReport failure -> [RestoreNodeId]
restoreReportBlocked report =
  [ restoreResultNode result
  | result <- restoreReportResults report
  , isBlocked (restoreResultOutcome result)
  ]
 where
  isBlocked (NodeBlocked _) = True
  isBlocked _ = False

-- | The total executor. Runs every node whose @'RequiresSuccess'@ dependencies
-- all succeeded and whose @'RequiresAttempt'@ dependencies were all reached,
-- records 'NodeBlocked' with the offending ids otherwise, and NEVER stops early.
-- The nodes are processed in their graph order, which 'buildRestoreGraph' emits
-- dependencies-before-dependents.
runRestoreGraphWith
  :: (Monad m)
  => (RestoreNodeId -> m (Either failure ()))
  -> RestoreGraph
  -> m (RestoreReport failure)
runRestoreGraphWith runNode graph = do
  results <- go Map.empty (restoreGraphNodes graph)
  pure (RestoreReport results)
 where
  go _ [] = pure []
  go outcomes (node : rest) = do
    let blockers = unsatisfiedDependencies outcomes (restoreNodeDependencies node)
    result <-
      if not (null blockers)
        then pure (NodeBlocked blockers)
        else do
          ran <- runNode (restoreNodeId node)
          pure (either NodeFailed (const NodeSucceeded) ran)
    let outcomes' = Map.insert (restoreNodeId node) result outcomes
    remaining <- go outcomes' rest
    pure (RestoreNodeResult (restoreNodeId node) result : remaining)

-- | The dependency ids that are not satisfied given the outcomes so far. A
-- @'RequiresSuccess'@ dependency is satisfied only by 'NodeSucceeded'; a
-- @'RequiresAttempt'@ dependency by any recorded outcome (i.e. it was reached and
-- not itself blocked).
unsatisfiedDependencies
  :: Map RestoreNodeId (RestoreOutcome failure) -> [RestoreDependency] -> [RestoreNodeId]
unsatisfiedDependencies outcomes dependencies =
  [ restoreDependencyOn dependency
  | dependency <- dependencies
  , not (dependencySatisfied dependency)
  ]
 where
  dependencySatisfied dependency =
    case (restoreDependencyKind dependency, Map.lookup (restoreDependencyOn dependency) outcomes) of
      (RequiresSuccess, Just NodeSucceeded) -> True
      (RequiresSuccess, _) -> False
      (RequiresAttempt, Just (NodeBlocked _)) -> False
      (RequiresAttempt, Just _) -> True
      (RequiresAttempt, Nothing) -> False
