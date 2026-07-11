{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Capacity.Config
  ( CapacityBudget (..)
  , CapacitySection (..)
  , ChildProcessBudgetConfig (..)
  , MilliCpu (..)
  , MebiBytes (..)
  , NamespaceQuota (..)
  , ResourceEnvelope (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  , RuntimeMemoryProfile (..)
  , WorkloadResourceProfile (..)
  , defaultCapacitySection
  , defaultRuntimeMemoryProfiles
  , defaultResourcePlan
  , fitsWithin
  , mkMebiBytes
  , mkMilliCpu
  , mkResourceEnvelope
  , plusResourceVector
  , resourceVectorFitsWithin
  , resourceVectorMinus
  , resourceVectorScale
  , runtimeMemoryPlanForProfile
  , storageFitsWithin
  , plusBudget
  , validateCapacitySection
  , validateResourcePlan
  )
where

import Control.Monad (forM_, unless)
import Data.Char qualified as Char
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall
  ( FromDhall (..)
  , InterpretOptions (..)
  , ToDhall (..)
  , defaultInterpretOptions
  , genericAutoWith
  , genericToDhallWith
  )
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory

newtype MilliCpu = MilliCpu {unMilliCpu :: Natural}
  deriving (Eq, Show)

mkMilliCpu :: Natural -> Either String MilliCpu
mkMilliCpu value
  | value > 0 = Right (MilliCpu value)
  | otherwise = Left "cpu must be positive"

newtype MebiBytes = MebiBytes {unMebiBytes :: Natural}
  deriving (Eq, Show)

mkMebiBytes :: Natural -> Either String MebiBytes
mkMebiBytes value
  | value > 0 = Right (MebiBytes value)
  | otherwise = Left "MiB value must be positive"

data CapacityBudget = CapacityBudget
  { budgetCpu :: Natural
  , budgetMemory :: Natural
  , budgetStorage :: Natural
  }
  deriving (Eq, Show, Generic)

instance FromDhall CapacityBudget where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = stripBudgetPrefix}

instance ToDhall CapacityBudget where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = stripBudgetPrefix}

stripBudgetPrefix :: Text -> Text
stripBudgetPrefix value =
  case Text.stripPrefix "budget" value of
    Just stripped -> lowerFirst stripped
    Nothing -> value

data ResourceVector = ResourceVector
  { milli_cpu :: Natural
  , memory_mib :: Natural
  , ephemeral_storage_mib :: Natural
  , durable_storage_mib :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data ResourceEnvelope = ResourceEnvelope
  { request :: ResourceVector
  , limit :: ResourceVector
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data NamespaceQuota = NamespaceQuota
  { namespace_name :: Text
  , quota :: ResourceVector
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data WorkloadResourceProfile = WorkloadResourceProfile
  { profile_id :: Text
  , profile_namespace :: Text
  , replicas :: Natural
  , resources :: ResourceEnvelope
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data ResourcePlan = ResourcePlan
  { host_capacity :: ResourceVector
  , rke2_reserved :: ResourceVector
  , eviction_floor :: ResourceVector
  , namespace_quotas :: [NamespaceQuota]
  , workload_profiles :: [WorkloadResourceProfile]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Authored child-process schedule inputs for one runtime. A missing permit
-- capacity or deadline represents an unbounded schedule and is rejected when
-- the runtime-memory profile is compiled. Each list entry is the admitted peak
-- for one simultaneously running child; a capacity greater than one therefore
-- has to enumerate and sum every simultaneous peak.
data ChildProcessBudgetConfig = ChildProcessBudgetConfig
  { permit_capacity :: Maybe Natural
  , action_deadline_milliseconds :: Maybe Natural
  , simultaneous_peak_bytes :: [Natural]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Raw Tier-0 inputs for a validated runtime-memory plan. The profile id is
-- also the id of the matching 'WorkloadResourceProfile'; its container limit
-- is derived from that profile rather than authored a second time.
data RuntimeMemoryProfile = RuntimeMemoryProfile
  { runtime_profile_id :: Text
  , bounded_application_state_bytes :: Natural
  , bounded_pending_persistence_state_bytes :: Natural
  , bounded_in_heap_transport_decode_bytes :: Natural
  , other_heap_reserve_bytes :: Natural
  , heap_cap_bytes :: Natural
  , native_non_heap_reserve_bytes :: Natural
  , child_process_budget :: ChildProcessBudgetConfig
  , kernel_cgroup_reserve_bytes :: Natural
  , safety_margin_bytes :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data CapacitySection = CapacitySection
  { node_budget :: CapacityBudget
  , workload_budget :: CapacityBudget
  , region_quota :: CapacityBudget
  , resource_plan :: ResourcePlan
  , runtime_memory_profiles :: [RuntimeMemoryProfile]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

defaultCapacitySection :: CapacitySection
defaultCapacitySection =
  CapacitySection
    { node_budget = CapacityBudget 8 16 100
    , workload_budget = CapacityBudget 4 8 40
    , region_quota = CapacityBudget 32 64 500
    , resource_plan = defaultResourcePlan
    , runtime_memory_profiles = defaultRuntimeMemoryProfiles
    }

defaultRuntimeMemoryProfiles :: [RuntimeMemoryProfile]
defaultRuntimeMemoryProfiles =
  [ RuntimeMemoryProfile
      { runtime_profile_id = "gateway"
      , bounded_application_state_bytes = mebibytes 64
      , bounded_pending_persistence_state_bytes = mebibytes 16
      , bounded_in_heap_transport_decode_bytes = mebibytes 64
      , other_heap_reserve_bytes = mebibytes 48
      , heap_cap_bytes = mebibytes 256
      , native_non_heap_reserve_bytes = mebibytes 64
      , child_process_budget =
          ChildProcessBudgetConfig
            { permit_capacity = Just 1
            , action_deadline_milliseconds = Just 30000
            , simultaneous_peak_bytes = [mebibytes 64]
            }
      , kernel_cgroup_reserve_bytes = mebibytes 32
      , safety_margin_bytes = mebibytes 64
      }
  ]
 where
  mebibytes value = value * 1024 * 1024

defaultResourcePlan :: ResourcePlan
defaultResourcePlan =
  ResourcePlan
    { host_capacity = ResourceVector 8000 15872 100000 180000
    , rke2_reserved = ResourceVector 1000 2048 10240 1024
    , eviction_floor = ResourceVector 500 1024 10240 1024
    , namespace_quotas =
        [ NamespaceQuota "keycloak" (ResourceVector 2025 4448 12000 61440)
        , NamespaceQuota "vscode" (ResourceVector 2425 5216 10944 112640)
        , NamespaceQuota "api" (ResourceVector 500 768 2000 1000)
        , NamespaceQuota "websocket" (ResourceVector 500 768 3000 1000)
        , NamespaceQuota "gateway" (ResourceVector 1250 3584 6000 20480)
        , NamespaceQuota "prodbox" (ResourceVector 1000 1792 5000 20480)
        , NamespaceQuota "vault" (ResourceVector 300 512 2000 1024)
        ]
    , workload_profiles =
        [ workload "keycloak" "keycloak" 1 (ResourceVector 500 1024 1024 1) (ResourceVector 600 1280 2048 1)
        , workload
            "keycloak-vault-secrets"
            "keycloak"
            1
            (ResourceVector 50 128 256 1)
            (ResourceVector 100 256 512 1)
        , workload
            "keycloak-postgres"
            "keycloak"
            3
            (ResourceVector 250 512 1024 1024)
            (ResourceVector 350 768 2048 2048)
        , workload
            "keycloak-postgres-replica-cert-copy"
            "keycloak"
            3
            (ResourceVector 10 16 32 1)
            (ResourceVector 25 32 64 1)
        , workload
            "keycloak-postgres-vault-secrets"
            "keycloak"
            1
            (ResourceVector 50 128 256 1)
            (ResourceVector 100 256 512 1)
        , workload
            "keycloak-postgres-secret-materializer"
            "keycloak"
            1
            (ResourceVector 50 128 256 1)
            (ResourceVector 100 256 512 1)
        , workload
            "vscode"
            "vscode"
            1
            (ResourceVector 500 1024 1024 1024)
            (ResourceVector 600 1280 2048 2048)
        , workload
            "vscode-vault-secrets"
            "vscode"
            1
            (ResourceVector 50 128 256 1)
            (ResourceVector 100 256 512 1)
        , workload
            "vscode-secret-materializer"
            "vscode"
            1
            (ResourceVector 50 128 256 1)
            (ResourceVector 100 256 512 1)
        , workload "api" "api" 2 (ResourceVector 250 256 512 1) (ResourceVector 250 384 512 1)
        , workload "websocket" "websocket" 2 (ResourceVector 100 256 512 1) (ResourceVector 150 256 512 1)
        , workload "redis" "websocket" 1 (ResourceVector 100 256 512 1) (ResourceVector 150 256 512 1)
        , workload "gateway" "gateway" 3 (ResourceVector 250 256 512 1) (ResourceVector 250 512 512 1)
        , workload "pulsar" "gateway" 1 (ResourceVector 250 1024 1024 1) (ResourceVector 500 2048 4096 1)
        , workload
            "minio"
            "prodbox"
            1
            (ResourceVector 250 512 1024 1024)
            (ResourceVector 500 1024 2048 2048)
        , workload "harbor" "prodbox" 1 (ResourceVector 200 256 512 1024) (ResourceVector 300 512 1024 2048)
        , workload
            "percona-postgres-operator"
            "prodbox"
            1
            (ResourceVector 100 128 512 1)
            (ResourceVector 150 256 1024 1)
        , workload "vault" "vault" 1 (ResourceVector 200 256 1024 1) (ResourceVector 250 512 1024 1)
        ]
    }
 where
  workload profile namespace count req lim =
    WorkloadResourceProfile
      { profile_id = profile
      , profile_namespace = namespace
      , replicas = count
      , resources = ResourceEnvelope {request = req, limit = lim}
      }

fitsWithin :: CapacityBudget -> CapacityBudget -> Bool
fitsWithin inner outer =
  budgetCpu inner <= budgetCpu outer
    && budgetMemory inner <= budgetMemory outer
    && budgetStorage inner <= budgetStorage outer

storageFitsWithin :: CapacityBudget -> CapacityBudget -> Bool
storageFitsWithin inner outer =
  budgetStorage inner <= budgetStorage outer

plusBudget :: CapacityBudget -> CapacityBudget -> CapacityBudget
plusBudget left right =
  CapacityBudget
    { budgetCpu = budgetCpu left + budgetCpu right
    , budgetMemory = budgetMemory left + budgetMemory right
    , budgetStorage = budgetStorage left + budgetStorage right
    }

mkResourceEnvelope :: ResourceVector -> ResourceVector -> Either String ResourceEnvelope
mkResourceEnvelope requested limited = do
  validatePositiveRuntimeVector "resource request" requested
  validatePositiveRuntimeVector "resource limit" limited
  unless
    (requested `resourceVectorFitsWithin` limited)
    (Left "resource request must fit within resource limit")
  Right ResourceEnvelope {request = requested, limit = limited}

resourceVectorFitsWithin :: ResourceVector -> ResourceVector -> Bool
resourceVectorFitsWithin inner outer =
  milli_cpu inner <= milli_cpu outer
    && memory_mib inner <= memory_mib outer
    && ephemeral_storage_mib inner <= ephemeral_storage_mib outer
    && durable_storage_mib inner <= durable_storage_mib outer

plusResourceVector :: ResourceVector -> ResourceVector -> ResourceVector
plusResourceVector left right =
  ResourceVector
    { milli_cpu = milli_cpu left + milli_cpu right
    , memory_mib = memory_mib left + memory_mib right
    , ephemeral_storage_mib = ephemeral_storage_mib left + ephemeral_storage_mib right
    , durable_storage_mib = durable_storage_mib left + durable_storage_mib right
    }

resourceVectorMinus :: ResourceVector -> ResourceVector -> ResourceVector
resourceVectorMinus left right =
  ResourceVector
    { milli_cpu = boundedMinus (milli_cpu left) (milli_cpu right)
    , memory_mib = boundedMinus (memory_mib left) (memory_mib right)
    , ephemeral_storage_mib = boundedMinus (ephemeral_storage_mib left) (ephemeral_storage_mib right)
    , durable_storage_mib = boundedMinus (durable_storage_mib left) (durable_storage_mib right)
    }

resourceVectorScale :: Natural -> ResourceVector -> ResourceVector
resourceVectorScale factor vector =
  ResourceVector
    { milli_cpu = factor * milli_cpu vector
    , memory_mib = factor * memory_mib vector
    , ephemeral_storage_mib = factor * ephemeral_storage_mib vector
    , durable_storage_mib = factor * durable_storage_mib vector
    }

validateCapacitySection :: CapacitySection -> Either String ()
validateCapacitySection section = do
  unlessFits
    "capacity.workload_budget must fit within capacity.node_budget"
    (workload_budget section)
    (node_budget section)
  unlessFits
    "capacity.node_budget must fit within capacity.region_quota"
    (node_budget section)
    (region_quota section)
  validateResourcePlan (resource_plan section)
  _ <- validateRuntimeMemoryProfiles section
  Right ()

-- | Resolve one opaque runtime plan by the existing workload-profile id. The
-- matching Kubernetes memory limit is converted from MiB to exact bytes here,
-- so the runtime proof and admission envelope cannot drift independently.
runtimeMemoryPlanForProfile
  :: CapacitySection -> Text -> Either String RuntimeMemory.RuntimeMemoryPlan
runtimeMemoryPlanForProfile section requestedProfileId = do
  validateResourcePlan (resource_plan section)
  plans <- validateRuntimeMemoryProfiles section
  case find ((== requestedProfileId) . fst) plans of
    Just (_, plan) -> Right plan
    Nothing ->
      Left
        ( "capacity.runtime_memory_profiles is missing profile `"
            ++ Text.unpack requestedProfileId
            ++ "`"
        )

validateRuntimeMemoryProfiles
  :: CapacitySection -> Either String [(Text, RuntimeMemory.RuntimeMemoryPlan)]
validateRuntimeMemoryProfiles section = do
  let profiles = runtime_memory_profiles section
      profileIds = map runtime_profile_id profiles
  unless
    (not (null profiles))
    (Left "capacity.runtime_memory_profiles must not be empty")
  unless
    (length profileIds == Set.size (Set.fromList profileIds))
    (Left "capacity.runtime_memory_profiles must have unique runtime_profile_id values")
  traverse (compileRuntimeMemoryProfile (resource_plan section)) profiles

compileRuntimeMemoryProfile
  :: ResourcePlan
  -> RuntimeMemoryProfile
  -> Either String (Text, RuntimeMemory.RuntimeMemoryPlan)
compileRuntimeMemoryProfile plan profile = do
  let profileId = Text.strip (runtime_profile_id profile)
      label fieldName =
        "capacity.runtime_memory_profiles["
          ++ Text.unpack profileId
          ++ "]."
          ++ fieldName
  unless
    (not (Text.null profileId))
    (Left "capacity.runtime_memory_profiles[].runtime_profile_id must not be empty")
  workloadProfile <-
    case find ((== profileId) . profile_id) (workload_profiles plan) of
      Just matched -> Right matched
      Nothing ->
        Left
          ( "capacity.runtime_memory_profiles["
              ++ Text.unpack profileId
              ++ "] references unknown workload profile"
          )
  applicationState <-
    positiveBytes
      (label "bounded_application_state_bytes")
      RuntimeMemory.BoundedApplicationState
      (bounded_application_state_bytes profile)
  pendingPersistence <-
    positiveBytes
      (label "bounded_pending_persistence_state_bytes")
      RuntimeMemory.BoundedPendingPersistenceState
      (bounded_pending_persistence_state_bytes profile)
  transportScratch <-
    positiveBytes
      (label "bounded_in_heap_transport_decode_bytes")
      RuntimeMemory.InHeapTransportDecodeScratch
      (bounded_in_heap_transport_decode_bytes profile)
  heapReserve <-
    positiveBytes
      (label "other_heap_reserve_bytes")
      RuntimeMemory.OtherHeapReserve
      (other_heap_reserve_bytes profile)
  heapCap <-
    positiveBytes (label "heap_cap_bytes") RuntimeMemory.HeapCap (heap_cap_bytes profile)
  nativeReserve <-
    positiveBytes
      (label "native_non_heap_reserve_bytes")
      RuntimeMemory.NativeNonHeapReserve
      (native_non_heap_reserve_bytes profile)
  kernelReserve <-
    positiveBytes
      (label "kernel_cgroup_reserve_bytes")
      RuntimeMemory.KernelCgroupReserve
      (kernel_cgroup_reserve_bytes profile)
  margin <-
    positiveBytes (label "safety_margin_bytes") RuntimeMemory.SafetyMargin (safety_margin_bytes profile)
  containerLimit <-
    positiveBytes
      (label "container_memory_limit")
      RuntimeMemory.ContainerMemoryLimit
      (memory_mib (limit (resources workloadProfile)) * 1024 * 1024)
  let childConfig = child_process_budget profile
      childSchedule =
        case permit_capacity childConfig of
          Nothing -> RuntimeMemory.UnboundedChildSchedule
          Just permitCount ->
            RuntimeMemory.BoundedChildSchedule
              { RuntimeMemory.rawChildPermitCount = permitCount
              , RuntimeMemory.rawChildDeadlineMicros =
                  fmap (* 1000) (action_deadline_milliseconds childConfig)
              , RuntimeMemory.rawChildPeakBytes = simultaneous_peak_bytes childConfig
              }
      inputs =
        RuntimeMemory.RuntimeMemoryInputs
          { RuntimeMemory.runtimeBoundedApplicationState = applicationState
          , RuntimeMemory.runtimeBoundedPendingPersistenceState = pendingPersistence
          , RuntimeMemory.runtimeInHeapTransportDecodeScratch = transportScratch
          , RuntimeMemory.runtimeOtherHeapReserve = heapReserve
          , RuntimeMemory.runtimeHeapCap = heapCap
          , RuntimeMemory.runtimeNativeNonHeapReserve = nativeReserve
          , RuntimeMemory.runtimeRawChildSchedule = childSchedule
          , RuntimeMemory.runtimeKernelCgroupReserve = kernelReserve
          , RuntimeMemory.runtimeSafetyMargin = margin
          , RuntimeMemory.runtimeContainerMemoryLimit = containerLimit
          }
  compiled <-
    either
      (\err -> Left (label "validation" ++ ": " ++ show err))
      Right
      (RuntimeMemory.validateRuntimeMemoryPlan inputs)
  Right (profileId, compiled)

positiveBytes
  :: String
  -> RuntimeMemory.MemoryTerm
  -> Natural
  -> Either String RuntimeMemory.PositiveBytes
positiveBytes label term value =
  either (Left . ((label ++ ": ") ++) . show) Right (RuntimeMemory.mkPositiveBytes term value)

validateResourcePlan :: ResourcePlan -> Either String ()
validateResourcePlan plan = do
  validatePositiveResourceVector "capacity.resource_plan.host_capacity" (host_capacity plan)
  validatePositiveResourceVector "capacity.resource_plan.rke2_reserved" (rke2_reserved plan)
  validatePositiveResourceVector "capacity.resource_plan.eviction_floor" (eviction_floor plan)
  unless
    ( (rke2_reserved plan `plusResourceVector` eviction_floor plan)
        `resourceVectorFitsWithin` host_capacity plan
    )
    (Left "capacity.resource_plan.rke2_reserved + eviction_floor must fit within host_capacity")
  let allocatable =
        host_capacity plan
          `resourceVectorMinus` rke2_reserved plan
          `resourceVectorMinus` eviction_floor plan
  unless
    (not (null (namespace_quotas plan)))
    (Left "capacity.resource_plan.namespace_quotas must not be empty")
  forM_ (namespace_quotas plan) validateNamespaceQuota
  forM_ (namespace_quotas plan) $ \namespaceQuota ->
    unless
      (quota namespaceQuota `resourceVectorFitsWithin` allocatable)
      ( Left
          ( "capacity.resource_plan.namespace_quotas["
              ++ Text.unpack (namespace_name namespaceQuota)
              ++ "].quota must fit within cluster allocatable capacity"
          )
      )
  unless
    (sumVectors (map quota (concurrentNamespaceQuotas plan)) `resourceVectorFitsWithin` allocatable)
    ( Left
        "capacity.resource_plan.concurrent_namespace_quotas must fit within cluster allocatable capacity"
    )
  unless
    (not (null (workload_profiles plan)))
    (Left "capacity.resource_plan.workload_profiles must not be empty")
  forM_ (workload_profiles plan) (validateWorkloadProfile plan)
  forM_ (namespace_quotas plan) $ \namespaceQuota -> do
    let namespaceName = namespace_name namespaceQuota
        workloadDraw =
          sumVectors
            [ workloadProfileDraw profile
            | profile <- workload_profiles plan
            , profile_namespace profile == namespaceName
            ]
    unless
      (workloadDraw `resourceVectorFitsWithin` quota namespaceQuota)
      ( Left
          ( "capacity.resource_plan.workload_profiles for namespace "
              ++ Text.unpack namespaceName
              ++ " must fit within that namespace quota"
          )
      )

concurrentNamespaceQuotas :: ResourcePlan -> [NamespaceQuota]
concurrentNamespaceQuotas plan =
  -- `keycloak` is a standalone root-chart surface. The supported runtime deploys
  -- Keycloak and its PostgreSQL dependency under `vscode`, so adding both quotas
  -- would double-count the same workload shape against the single-node host.
  filter ((/= "keycloak") . namespace_name) (namespace_quotas plan)

unlessFits :: String -> CapacityBudget -> CapacityBudget -> Either String ()
unlessFits message inner outer =
  if fitsWithin inner outer
    then Right ()
    else Left message

validateNamespaceQuota :: NamespaceQuota -> Either String ()
validateNamespaceQuota namespaceQuota = do
  unless
    (not (Text.null (Text.strip (namespace_name namespaceQuota))))
    (Left "capacity.resource_plan.namespace_quotas[].namespace_name must not be empty")
  validatePositiveResourceVector
    ( "capacity.resource_plan.namespace_quotas["
        ++ Text.unpack (namespace_name namespaceQuota)
        ++ "].quota"
    )
    (quota namespaceQuota)

validateWorkloadProfile :: ResourcePlan -> WorkloadResourceProfile -> Either String ()
validateWorkloadProfile plan profile = do
  unless
    (not (Text.null (Text.strip (profile_id profile))))
    (Left "capacity.resource_plan.workload_profiles[].profile_id must not be empty")
  unless
    (not (Text.null (Text.strip (profile_namespace profile))))
    ( Left
        ( "capacity.resource_plan.workload_profiles["
            ++ Text.unpack (profile_id profile)
            ++ "].profile_namespace must not be empty"
        )
    )
  unless
    (profile_namespace profile `elem` map namespace_name (namespace_quotas plan))
    ( Left
        ( "capacity.resource_plan.workload_profiles["
            ++ Text.unpack (profile_id profile)
            ++ "] references unknown namespace"
        )
    )
  unless
    (replicas profile > 0)
    ( Left
        ( "capacity.resource_plan.workload_profiles["
            ++ Text.unpack (profile_id profile)
            ++ "].replicas must be positive"
        )
    )
  validateResourceEnvelope
    ("capacity.resource_plan.workload_profiles[" ++ Text.unpack (profile_id profile) ++ "].resources")
    (resources profile)

validateResourceEnvelope :: String -> ResourceEnvelope -> Either String ()
validateResourceEnvelope label envelope = do
  validatePositiveRuntimeVector (label ++ ".request") (request envelope)
  validatePositiveRuntimeVector (label ++ ".limit") (limit envelope)
  unless
    (request envelope `resourceVectorFitsWithin` limit envelope)
    (Left (label ++ ".request must fit within " ++ label ++ ".limit"))

validatePositiveRuntimeVector :: String -> ResourceVector -> Either String ()
validatePositiveRuntimeVector label vector = do
  requirePositive (label ++ ".milli_cpu") (milli_cpu vector)
  requirePositive (label ++ ".memory_mib") (memory_mib vector)
  requirePositive (label ++ ".ephemeral_storage_mib") (ephemeral_storage_mib vector)
  requirePositive (label ++ ".durable_storage_mib") (durable_storage_mib vector)

validatePositiveResourceVector :: String -> ResourceVector -> Either String ()
validatePositiveResourceVector label vector = do
  validatePositiveRuntimeVector label vector

requirePositive :: String -> Natural -> Either String ()
requirePositive label value =
  unless (value > 0) (Left (label ++ " must be positive"))

workloadProfileDraw :: WorkloadResourceProfile -> ResourceVector
workloadProfileDraw profile =
  resourceVectorScale (replicas profile) (limit (resources profile))

sumVectors :: [ResourceVector] -> ResourceVector
sumVectors =
  foldl' plusResourceVector zeroResourceVector

zeroResourceVector :: ResourceVector
zeroResourceVector = ResourceVector 0 0 0 0

boundedMinus :: Natural -> Natural -> Natural
boundedMinus left right =
  if right <= left
    then left - right
    else 0

lowerFirst :: Text -> Text
lowerFirst value =
  case Text.uncons value of
    Just (firstChar, rest) -> Text.cons (Char.toLower firstChar) rest
    Nothing -> value
