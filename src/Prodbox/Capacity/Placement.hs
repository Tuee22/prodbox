{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Capacity.Placement
  ( WorkloadConcurrency (..)
  , renderedNamespace
  , concurrentPlanDraws
  , planNamespaceQuota
  , planNamespaceAdmission
  , planNamespaceLimits
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Prodbox.Capacity.Config
  ( ResourceEnvelope (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  , WorkloadConcurrency (..)
  , WorkloadResourceProfile (..)
  , resourceVectorScale
  , resources
  )
import Prodbox.Substrate (Substrate (..))

renderedNamespace :: Substrate -> Text -> Text
renderedNamespace substrate namespace =
  case substrate of
    SubstrateHomeLocal
      | namespace == "keycloak" -> "vscode"
    _ -> namespace

planNamespaceQuota :: Substrate -> Text -> ResourcePlan -> Either String ResourceVector
planNamespaceQuota substrate namespace plan =
  case placedProfiles substrate namespace plan of
    [] -> Left ("capacity.resource_plan has no workload rendered in namespace `" ++ show namespace ++ "`")
    profiles -> Right (concurrentDraw profiles)

planNamespaceAdmission :: Substrate -> Text -> ResourcePlan -> Either String ResourceEnvelope
planNamespaceAdmission substrate namespace plan =
  case placedProfiles substrate namespace plan of
    [] -> Left ("capacity.resource_plan has no workload rendered in namespace `" ++ show namespace ++ "`")
    profiles ->
      Right
        ResourceEnvelope
          { request = concurrentDrawWith (request . resources) profiles
          , limit = concurrentDrawWith (limit . resources) profiles
          }

planNamespaceLimits :: Substrate -> Text -> ResourcePlan -> Either String ResourceEnvelope
planNamespaceLimits substrate namespace plan =
  case placedProfiles substrate namespace plan of
    [] -> Left ("capacity.resource_plan has no workload rendered in namespace `" ++ show namespace ++ "`")
    profile : profiles ->
      Right
        ( foldl'
            maxEnvelope
            (resources profile)
            (map resources profiles)
        )

placedProfiles :: Substrate -> Text -> ResourcePlan -> [WorkloadResourceProfile]
placedProfiles substrate namespace plan =
  case rendered of
    [] ->
      [ profile
      | profile <- workload_profiles plan
      , profile_namespace profile == namespace
      ]
    profiles -> profiles
 where
  rendered =
    [ profile
    | profile <- workload_profiles plan
    , renderedNamespace substrate (profile_namespace profile) == namespace
    ]

-- | Draws that may coexist at cluster scope. Steady workloads are independent
-- allocations; mutually exclusive named windows contribute their componentwise
-- peak, so workloads within one window coexist while distinct windows do not.
concurrentPlanDraws :: ResourcePlan -> [ResourceVector]
concurrentPlanDraws plan =
  steadyDraws ++ Map.elems windowDraws
 where
  (steadyDraws, windowDraws) =
    foldl' collect ([], Map.empty) (workload_profiles plan)
  collect (steady, windows) profile =
    case workload_concurrency profile of
      Steady -> (profileRequestDraw profile : steady, windows)
      ExclusiveWindow window ->
        (steady, Map.insertWith maxVector window (profileRequestDraw profile) windows)

concurrentDraw :: [WorkloadResourceProfile] -> ResourceVector
concurrentDraw = concurrentDrawWith (limit . resources)

concurrentDrawWith
  :: (WorkloadResourceProfile -> ResourceVector)
  -> [WorkloadResourceProfile]
  -> ResourceVector
concurrentDrawWith vectorFor profiles =
  foldl' plusVector steadyTotal (Map.elems windowDraws)
 where
  (steadyTotal, windowDraws) =
    foldl' collect (zeroVector, Map.empty) profiles
  collect (steady, windows) profile =
    case workload_concurrency profile of
      Steady -> (plusVector steady (profileDrawWith vectorFor profile), windows)
      ExclusiveWindow window ->
        (steady, Map.insertWith maxVector window (profileDrawWith vectorFor profile) windows)

profileDrawWith
  :: (WorkloadResourceProfile -> ResourceVector)
  -> WorkloadResourceProfile
  -> ResourceVector
profileDrawWith vectorFor profile =
  resourceVectorScale (replicas profile + surge profile) (vectorFor profile)

profileRequestDraw :: WorkloadResourceProfile -> ResourceVector
profileRequestDraw profile =
  resourceVectorScale (replicas profile + surge profile) (request (resources profile))

zeroVector :: ResourceVector
zeroVector = ResourceVector 0 0 0 0

plusVector :: ResourceVector -> ResourceVector -> ResourceVector
plusVector left right =
  ResourceVector
    { milli_cpu = milli_cpu left + milli_cpu right
    , memory_mib = memory_mib left + memory_mib right
    , ephemeral_storage_mib = ephemeral_storage_mib left + ephemeral_storage_mib right
    , durable_storage_mib = durable_storage_mib left + durable_storage_mib right
    }

maxEnvelope :: ResourceEnvelope -> ResourceEnvelope -> ResourceEnvelope
maxEnvelope left right =
  ResourceEnvelope
    { request = maxVector (request left) (request right)
    , limit = maxVector (limit left) (limit right)
    }

maxVector :: ResourceVector -> ResourceVector -> ResourceVector
maxVector left right =
  ResourceVector
    { milli_cpu = max (milli_cpu left) (milli_cpu right)
    , memory_mib = max (memory_mib left) (memory_mib right)
    , ephemeral_storage_mib = max (ephemeral_storage_mib left) (ephemeral_storage_mib right)
    , durable_storage_mib = max (durable_storage_mib left) (durable_storage_mib right)
    }
