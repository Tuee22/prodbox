{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Capacity.Placement
  ( WorkloadConcurrency (..)
  , renderedNamespace
  , concurrentPlanDraws
  , planNamespaceQuota
  , planNamespaceAdmission
  , planNamespaceLimits
  , planForSubstrate
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config
  ( ResourceEnvelope (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  , WorkloadConcurrency (..)
  , WorkloadDemandSpec (..)
  , WorkloadResourceProfile (..)
  , resourceVectorScale
  , resources
  )
import Prodbox.Substrate (Substrate, gatewayEmitterJournalMiB, gatewayNodeIdsForSubstrate)

-- | The namespace a profile's workloads are installed into. The Keycloak
-- workloads are a dependency of the @vscode@ root chart, and a dependency is
-- installed into its root chart's namespace on every substrate, so they are
-- placed with @vscode@ on every substrate. A standalone @keycloak@ namespace
-- exists only as the dormant guardrail the home reconcile applies, and
-- 'placedProfiles' falls back to the profile namespace for it.
--
-- This once merged only on the home substrate, on the premise that AWS kept
-- Keycloak separate; the AWS restore set reconciles @vscode@ and never a
-- @keycloak@ root, so the AWS @vscode@ quota omitted roughly 1,330m of CPU
-- requests its own pods needed and admission rejected the @vscode@ Deployment.
renderedNamespace :: Substrate -> Text -> Text
renderedNamespace _ namespace
  | namespace == "keycloak" = "vscode"
  | otherwise = namespace

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
      [ substrateProfile substrate profile
      | profile <- workload_profiles plan
      , profile_namespace profile == namespace
      ]
    profiles -> profiles
 where
  rendered =
    [ substrateProfile substrate profile
    | profile <- workload_profiles plan
    , renderedNamespace substrate (profile_namespace profile) == namespace
    ]

-- | The profile as the substrate renders it. The gateway chart renders one
-- StatefulSet per entry of 'gatewayNodeIdsForSubstrate', two on the home and
-- three on EKS, whatever replica count the plan's profile states, and the AWS
-- emitters each claim a retained-EBS journal the home ones do not. A quota
-- derived from the plan's profile admitted two of the three AWS pods and left
-- the journal claims out of @requests.storage@. The default plan states the
-- home count, so the home numbers do not move.
substrateProfile :: Substrate -> WorkloadResourceProfile -> WorkloadResourceProfile
substrateProfile substrate profile
  | profile_id profile == "gateway" =
      profile
        { replicas = gatewayEmitterCount substrate
        , workload_demand =
            (workload_demand profile)
              { demanded_durable_storage_mib = gatewayEmitterJournalMiB substrate
              }
        }
  | otherwise = profile

-- | The plan as a substrate renders it, every profile through
-- 'substrateProfile'. A claim that is sized from a profile's durable storage has
-- to read it from here: the plan's own gateway profile states no durable storage
-- at all, so a journal claim sized from the plan alone is refused as having "no
-- durable PVC allocation" while the quota, which is placed through
-- 'substrateProfile', admits it.
planForSubstrate :: Substrate -> ResourcePlan -> ResourcePlan
planForSubstrate substrate plan =
  plan {workload_profiles = map (substrateProfile substrate) (workload_profiles plan)}

gatewayEmitterCount :: Substrate -> Natural
gatewayEmitterCount = fromIntegral . length . gatewayNodeIdsForSubstrate

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
