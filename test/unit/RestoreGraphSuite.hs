{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.20: pure proofs that the derived restore graph closes the
-- @F-RESTORE@ class — coverage, independence, orphan scan, and total-executor
-- totality with a fake interpreter. No cluster required.
module RestoreGraphSuite
  ( restoreGraphSuite
  )
where

import Data.Functor.Identity (Identity, runIdentity)
import Data.List (sort)
import Prodbox.Lifecycle.RestoreGraph
  ( RestoreDependency (..)
  , RestoreEdgeKind (..)
  , RestoreGraph (..)
  , RestoreNode (..)
  , RestoreNodeId (..)
  , RestoreReport
  , buildRestoreGraph
  , buildRestoreGraphForPlan
  , restoreCyclePlanRequirement
  , restoreCycleStepNodeId
  , restoreGraphCoverageComplete
  , restoreGraphNodeIds
  , restoreGraphOrphans
  , restoreReportBlocked
  , restoreReportFailed
  , restoreReportResults
  , restoreReportSucceeded
  , retainedNodesHaveNoChartLifetimeDependents
  , runRestoreGraphWith
  )
import Prodbox.Lifecycle.StoreLifetime (StoreLifetime (..))
import Prodbox.Substrate (Substrate (..))
import Prodbox.TestRestore
  ( RestoreChart (..)
  , RestoreCyclePlan (..)
  , RetainedSesRequirement (..)
  , buildRestoreCyclePlan
  )
import TestSupport

fakeRun :: [RestoreNodeId] -> RestoreNodeId -> Identity (Either String ())
fakeRun failing nodeId =
  pure (if nodeId `elem` failing then Left "boom" else Right ())

runGraph :: [RestoreNodeId] -> RestoreGraph -> RestoreReport String
runGraph failing graph = runIdentity (runRestoreGraphWith (fakeRun failing) graph)

restoreGraphSuite :: SuiteBuilder ()
restoreGraphSuite =
  describe "Sprint 5.20 derived restore graph and total executor" $ do
    let sesGraph = buildRestoreGraph SubstrateHomeLocal SesRequired
        plainGraph = buildRestoreGraph SubstrateHomeLocal SesNotRequired
        nodeCount = length (restoreGraphNodeIds sesGraph)

    describe "coverage" $ do
      it "covers exactly the derived node set with retained SES" $
        restoreGraphCoverageComplete SesRequired sesGraph `shouldBe` True
      it "covers exactly the derived node set without retained SES" $
        restoreGraphCoverageComplete SesNotRequired plainGraph `shouldBe` True
      it "omits the retained-SES node when SES is not required" $
        (RestoreNodePrepareRetainedSes `elem` restoreGraphNodeIds plainGraph) `shouldBe` False
      it "fails coverage when a node is dropped" $
        restoreGraphCoverageComplete
          SesRequired
          sesGraph {restoreGraphNodes = drop 1 (restoreGraphNodes sesGraph)}
          `shouldBe` False

    describe "independence (the F-RESTORE fix)" $ do
      it "has no chart-lifetime node requiring the retained-SES node's success" $
        retainedNodesHaveNoChartLifetimeDependents sesGraph `shouldBe` []
      it "detects a chart restoration wrongly gated on the retained-SES node" $ do
        let wronglyGateApiOnSes node
              | restoreNodeId node == RestoreNodeReconcileChart RestoreChartApi =
                  node
                    { restoreNodeDependencies =
                        RestoreDependency RestoreNodePrepareRetainedSes RequiresSuccess
                          : restoreNodeDependencies node
                    }
              | otherwise = node
            bad = sesGraph {restoreGraphNodes = map wronglyGateApiOnSes (restoreGraphNodes sesGraph)}
        retainedNodesHaveNoChartLifetimeDependents bad
          `shouldBe` [(RestoreNodeReconcileChart RestoreChartApi, RestoreNodePrepareRetainedSes)]

    describe "orphan scan" $ do
      it "finds no orphan in the derived graph" $
        restoreGraphOrphans sesGraph `shouldBe` []
      it "flags a node reading retained state through a chart-lifetime transport" $ do
        let orphan =
              RestoreNode
                { restoreNodeId = RestoreNodeWaitForPublicEdge
                , restoreNodeDependencies = []
                , restoreNodeTransportLifetime = ChartLifetime
                , restoreNodeReadsLifetime = ClusterRetained
                }
            bad = sesGraph {restoreGraphNodes = [orphan]}
        restoreGraphOrphans bad `shouldBe` [RestoreNodeWaitForPublicEdge]

    describe "plan wiring bijection (the live TestRunner dispatch is total)" $ do
      let sesPlan = buildRestoreCyclePlan SubstrateHomeLocal SesRequired
          plainPlan = buildRestoreCyclePlan SubstrateHomeLocal SesNotRequired
          stepNodeIds plan = sort (map restoreCycleStepNodeId (restoreCycleSteps plan))
          graphNodeIds plan = sort (restoreGraphNodeIds (buildRestoreGraphForPlan plan))
      it "maps every plan step onto a distinct graph node id (SES required)" $
        stepNodeIds sesPlan `shouldBe` graphNodeIds sesPlan
      it "maps every plan step onto a distinct graph node id (SES not required)" $
        stepNodeIds plainPlan `shouldBe` graphNodeIds plainPlan
      it "recovers SesRequired from a plan carrying the retained-SES step" $
        restoreCyclePlanRequirement sesPlan `shouldBe` SesRequired
      it "recovers SesNotRequired from a plan without the retained-SES step" $
        restoreCyclePlanRequirement plainPlan `shouldBe` SesNotRequired

    describe "total executor" $ do
      it "runs every node when all succeed" $ do
        let report = runGraph [] sesGraph
        length (restoreReportSucceeded report) `shouldBe` nodeCount
        restoreReportFailed report `shouldBe` []
        restoreReportBlocked report `shouldBe` []
      it "keeps the independent app charts running when retained-SES fails" $ do
        let report = runGraph [RestoreNodePrepareRetainedSes] sesGraph
        restoreReportFailed report `shouldBe` [RestoreNodePrepareRetainedSes]
        (RestoreNodeReconcileChart RestoreChartVscode `elem` restoreReportSucceeded report) `shouldBe` True
        (RestoreNodeReconcileChart RestoreChartApi `elem` restoreReportSucceeded report) `shouldBe` True
        (RestoreNodeReconcileChart RestoreChartWebsocket `elem` restoreReportSucceeded report)
          `shouldBe` True
        -- Nothing is silently discarded: every node appears in the report.
        length (restoreReportResults report) `shouldBe` nodeCount
      it "blocks dependents of a failed RequiresSuccess dependency and aggregates all outcomes" $ do
        let report = runGraph [RestoreNodeEnsureGatewayMinioBootstrap] sesGraph
        restoreReportFailed report `shouldBe` [RestoreNodeEnsureGatewayMinioBootstrap]
        (RestoreNodeReconcileChart RestoreChartGateway `elem` restoreReportBlocked report) `shouldBe` True
        (RestoreNodeReconcileChart RestoreChartApi `elem` restoreReportBlocked report) `shouldBe` True
        length (restoreReportResults report) `shouldBe` nodeCount
