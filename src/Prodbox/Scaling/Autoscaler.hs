{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.34: pure autoscaler planning. The live reconciler remains an
-- interpreter over this plan; the safety rules live here so capacity checks,
-- federation trust-tree placement, and gateway-leader preservation are
-- testable without a deployed federation.
module Prodbox.Scaling.Autoscaler
  ( AutoscalerInput (..)
  , ClusterCapacity (..)
  , ScalingAction (..)
  , ScalingIntent (..)
  , ScalingPlan (..)
  , ScalingPlanResult (..)
  , ScalingRefusal (..)
  , autoscalerPlan
  , capacityScaledResourceNames
  , clusterInTrustTree
  , orderScalingActions
  )
where

import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Prodbox.Capacity.Config
  ( CapacityBudget
  , fitsWithin
  )
import Prodbox.Cluster.Federation
  ( ChildMetadata (..)
  )

data ClusterCapacity = ClusterCapacity
  { clusterCapacityClusterId :: Text
  , clusterCapacityAvailable :: CapacityBudget
  }
  deriving (Eq, Show)

data ScalingIntent
  = ScaleWorkloadUp Text CapacityBudget
  | ScaleWorkloadDown Text
  deriving (Eq, Show)

data ScalingAction
  = ScalingActionScaleUp Text CapacityBudget
  | ScalingActionScaleDown Text
  deriving (Eq, Show)

newtype ScalingPlan = ScalingPlan
  { scalingPlanActions :: [ScalingAction]
  }
  deriving (Eq, Show)

data ScalingRefusal
  = ScalingTargetOutsideTrustTree Text
  | ScalingTargetCapacityUnknown Text
  | ScalingInsufficientCapacity Text CapacityBudget CapacityBudget
  | ScalingWouldRemoveGatewayLeader Text
  deriving (Eq, Show)

data ScalingPlanResult
  = ScalingPlanAccepted ScalingPlan
  | ScalingPlanRefused ScalingRefusal
  deriving (Eq, Show)

data AutoscalerInput = AutoscalerInput
  { autoscalerRootClusterId :: Text
  , autoscalerChildren :: [ChildMetadata]
  , autoscalerClusterCapacities :: [ClusterCapacity]
  , autoscalerGatewayLeaderClusterId :: Text
  , autoscalerIntents :: [ScalingIntent]
  }
  deriving (Eq, Show)

capacityScaledResourceNames :: [String]
capacityScaledResourceNames =
  [ "gateway"
  , "keycloak"
  , "keycloak-postgres"
  , "vscode"
  , "api"
  , "redis"
  , "websocket"
  ]

autoscalerPlan :: AutoscalerInput -> ScalingPlanResult
autoscalerPlan input =
  case traverse (intentAction input) (autoscalerIntents input) of
    Left refusal -> ScalingPlanRefused refusal
    Right actions -> ScalingPlanAccepted (ScalingPlan (orderScalingActions actions))

intentAction :: AutoscalerInput -> ScalingIntent -> Either ScalingRefusal ScalingAction
intentAction input intent =
  case intent of
    ScaleWorkloadUp clusterId needed -> do
      ensureTrusted input clusterId
      available <- lookupCapacity input clusterId
      if needed `fitsWithin` available
        then Right (ScalingActionScaleUp clusterId needed)
        else Left (ScalingInsufficientCapacity clusterId needed available)
    ScaleWorkloadDown clusterId -> do
      ensureTrusted input clusterId
      if clusterId == autoscalerGatewayLeaderClusterId input
        then Left (ScalingWouldRemoveGatewayLeader clusterId)
        else Right (ScalingActionScaleDown clusterId)

ensureTrusted :: AutoscalerInput -> Text -> Either ScalingRefusal ()
ensureTrusted input clusterId =
  if clusterInTrustTree (autoscalerRootClusterId input) (autoscalerChildren input) clusterId
    then Right ()
    else Left (ScalingTargetOutsideTrustTree clusterId)

lookupCapacity :: AutoscalerInput -> Text -> Either ScalingRefusal CapacityBudget
lookupCapacity input clusterId =
  case find ((== clusterId) . clusterCapacityClusterId) (autoscalerClusterCapacities input) of
    Nothing -> Left (ScalingTargetCapacityUnknown clusterId)
    Just capacity -> Right (clusterCapacityAvailable capacity)

clusterInTrustTree :: Text -> [ChildMetadata] -> Text -> Bool
clusterInTrustTree rootClusterId children targetClusterId =
  go Set.empty targetClusterId
 where
  go seen clusterId
    | clusterId == rootClusterId = True
    | clusterId `Set.member` seen = False
    | otherwise =
        case find ((== clusterId) . childMetadataClusterId) children of
          Nothing -> False
          Just metadata -> go (Set.insert clusterId seen) (childMetadataParentClusterId metadata)

orderScalingActions :: [ScalingAction] -> [ScalingAction]
orderScalingActions actions =
  filter isScaleUp actions ++ filter (not . isScaleUp) actions
 where
  isScaleUp action =
    case action of
      ScalingActionScaleUp _ _ -> True
      ScalingActionScaleDown _ -> False
