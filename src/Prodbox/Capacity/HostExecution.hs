{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Arithmetic for a host interpreter, serial command and expiry helper,
-- optionally with a separately funded persistent transport.
-- The runtime-memory outer ceiling funds the whole slice, not each member.
-- A plan still needs observed kernel placement, concurrency and Authority
-- admission; copying this pure value does not allocate another runtime slot.
module Prodbox.Capacity.HostExecution
  ( HostExecutionDemand (..)
  , HostTransportDemand (..)
  , HostTransportLimits
  , hostTransportCpuUsecPerSec
  , hostTransportTasks
  , hostTransportMemoryBytes
  , HostExecutionTopology (..)
  , HostExecutionPlanFor
  , HostExecutionPlan
  , HostExecutionTransportPlan
  , HostExecutionError (..)
  , compileHostExecutionPlan
  , compileHostExecutionPlanWithTransport
  , hostExecutionTransportLimits
  , hostExecutionSourcePlan
  , hostExecutionRuntimeMemory
  , hostExecutionDraw
  , hostExecutionRemaining
  , hostExecutionParentMemoryBytes
  , hostExecutionChildMemoryBytes
  , hostExecutionHelperMemoryBytes
  , hostExecutionSliceMemoryBytes
  , hostExecutionParentCpuUsecPerSec
  , hostExecutionChildCpuUsecPerSec
  , hostExecutionHelperCpuUsecPerSec
  , hostExecutionSliceCpuUsecPerSec
  , hostExecutionParentTasks
  , hostExecutionChildTasks
  , hostExecutionHelperTasks
  , hostExecutionSliceTasks
  , hostExecutionMaximumChildMicros
  ) where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.Config (ResourcePlan, ResourceVector (..))
import Prodbox.Capacity.ObservedHost (ObservedHostRoot)
import Prodbox.Capacity.RuntimeMemory qualified as Runtime

-- | Explicit declarations, never inferred from a diagnostic fixture. CPU is
-- microseconds per second, in whole percent steps matching systemd/cgroup2.
-- The runtime-memory child reserve must fund child plus helper simultaneously.
data HostExecutionDemand = HostExecutionDemand
  { parentCpuUsecPerSec :: !Natural
  , childCpuUsecPerSec :: !Natural
  , helperCpuUsecPerSec :: !Natural
  , parentTasks :: !Natural
  , childTasks :: !Natural
  , helperTasks :: !Natural
  , childMemoryBytes :: !Natural
  , helperMemoryBytes :: !Natural
  , ephemeralStorageMib :: !Natural
  , durableStorageMib :: !Natural
  }
  deriving (Eq, Show)

data HostTransportDemand = HostTransportDemand
  { transportCpuUsecPerSec :: !Natural
  , transportTasks :: !Natural
  , transportMemoryBytes :: !Natural
  }
  deriving (Eq, Show)

data HostTransportLimits = HostTransportLimits !Word64 !Word64 !Word64
  deriving (Eq, Show)

hostTransportCpuUsecPerSec
  , hostTransportTasks
  , hostTransportMemoryBytes
    :: HostTransportLimits -> Word64
hostTransportCpuUsecPerSec (HostTransportLimits cpu _ _) = cpu
hostTransportTasks (HostTransportLimits _ tasks _) = tasks
hostTransportMemoryBytes (HostTransportLimits _ _ memory) = memory

data HostExecutionTopology = HostSerialCommands | HostSerialCommandsWithTransport

data HostExecutionRoles topology where
  HostSerialRoles :: HostExecutionRoles 'HostSerialCommands
  HostTransportRoles :: !HostTransportLimits -> HostExecutionRoles 'HostSerialCommandsWithTransport

deriving instance Eq (HostExecutionRoles topology)
deriving instance Show (HostExecutionRoles topology)

data HostExecutionError
  = HostExecutionInvalidBound
  | HostExecutionCpuGranularity
  | HostExecutionScheduleNotSerial
  | HostExecutionScheduleNotPaired
  | HostExecutionTransportPeakMismatch
  | HostExecutionChildReserveMismatch
  | HostExecutionParentReserveInvalid
  | HostExecutionObservedHostRefused !Allocation.CompileError
  | HostExecutionOverCommitted !Allocation.CompileError
  deriving (Eq, Show)

data HostExecutionPlanFor (topology :: HostExecutionTopology)
  = HostExecutionPlan
      !ResourcePlan
      !Runtime.RuntimeMemoryPlan
      !HostExecutionDemand
      !ResourceVector
      !ResourceVector
      !Word64
      !Word64
      !Word64
      !Word64
      !(HostExecutionRoles topology)
  deriving (Eq, Show)

-- Existing serial placement cannot consume a plan with an additional role.
-- The latter requires a physical owner for its complete indexed family.
type HostExecutionPlan = HostExecutionPlanFor 'HostSerialCommands
type HostExecutionTransportPlan = HostExecutionPlanFor 'HostSerialCommandsWithTransport

compileHostExecutionPlan
  :: ObservedHostRoot
  -> Allocation.SomeAllocatedPlan
  -> Runtime.RuntimeMemoryPlan
  -> HostExecutionDemand
  -> Either HostExecutionError HostExecutionPlan
compileHostExecutionPlan = compileHostExecutionPlanFor HostSerialRoles

compileHostExecutionPlanWithTransport
  :: ObservedHostRoot
  -> Allocation.SomeAllocatedPlan
  -> Runtime.RuntimeMemoryPlan
  -> HostExecutionDemand
  -> HostTransportDemand
  -> Either HostExecutionError HostExecutionTransportPlan
compileHostExecutionPlanWithTransport observed allocated runtime demand transport = do
  let values = [transportCpuUsecPerSec transport, transportTasks transport, transportMemoryBytes transport]
  unless
    (all (\value -> value > 0 && value < fromIntegral (maxBound :: Word64)) values)
    (Left HostExecutionInvalidBound)
  unless (transportCpuUsecPerSec transport `mod` 10000 == 0) (Left HostExecutionCpuGranularity)
  let limits =
        HostTransportLimits
          (fromIntegral (transportCpuUsecPerSec transport))
          (fromIntegral (transportTasks transport))
          (fromIntegral (transportMemoryBytes transport))
  compileHostExecutionPlanFor (HostTransportRoles limits) observed allocated runtime demand

compileHostExecutionPlanFor
  :: HostExecutionRoles topology
  -> ObservedHostRoot
  -> Allocation.SomeAllocatedPlan
  -> Runtime.RuntimeMemoryPlan
  -> HostExecutionDemand
  -> Either HostExecutionError (HostExecutionPlanFor topology)
compileHostExecutionPlanFor roles observed allocated runtime demand = do
  checked <-
    first
      HostExecutionObservedHostRefused
      (Allocation.compileResourcePlanAgainstObserved observed allocated)
  let (transportCpu, transportTaskCount, transportMemory) = transportDraw roles
      cpu =
        parentCpuUsecPerSec demand + childCpuUsecPerSec demand + helperCpuUsecPerSec demand + transportCpu
      tasks = parentTasks demand + childTasks demand + helperTasks demand + transportTaskCount
      commandReserve = childMemoryBytes demand + helperMemoryBytes demand
      childReserve = commandReserve + transportMemory
      memory = Runtime.positiveBytesValue (Runtime.runtimeMemoryContainerLimitBytes runtime)
      children = Runtime.runtimeMemoryChildBudget runtime
      deadline = Runtime.childProcessDeadlineMicros children
      finite value = value > 0 && value < fromIntegral (maxBound :: Word64)
  unless
    ( all
        finite
        [ parentCpuUsecPerSec demand
        , childCpuUsecPerSec demand
        , helperCpuUsecPerSec demand
        , parentTasks demand
        , childTasks demand
        , helperTasks demand
        , childMemoryBytes demand
        , helperMemoryBytes demand
        , cpu
        , tasks
        , childReserve
        , memory
        , deadline
        ]
        && all (< fromIntegral (maxBound :: Word64)) [ephemeralStorageMib demand, durableStorageMib demand]
    )
    (Left HostExecutionInvalidBound)
  unless
    ( all
        ((== 0) . (`mod` 10000))
        [parentCpuUsecPerSec demand, childCpuUsecPerSec demand, helperCpuUsecPerSec demand]
    )
    (Left HostExecutionCpuGranularity)
  case roles of
    HostSerialRoles ->
      unless (Runtime.childProcessPermitCount children == 1) (Left HostExecutionScheduleNotSerial)
    HostTransportRoles _ ->
      unless (Runtime.childProcessPermitCount children == 2) (Left HostExecutionScheduleNotPaired)
  unless
    (Runtime.positiveBytesValue (Runtime.childProcessReservedPeakBytes children) == childReserve)
    (Left HostExecutionChildReserveMismatch)
  case roles of
    HostSerialRoles -> pure ()
    HostTransportRoles _ -> case Runtime.childProcessConcurrentPair children of
      Just (commandPeak, transportPeak) ->
        unless
          ( Runtime.positiveBytesValue commandPeak == commandReserve
              && Runtime.positiveBytesValue transportPeak == transportMemory
          )
          (Left HostExecutionTransportPeakMismatch)
      Nothing -> Left HostExecutionTransportPeakMismatch
  unless (childReserve < memory) (Left HostExecutionParentReserveInvalid)
  let parentMemory = memory - childReserve
      -- The opaque memory proof already bounds heap/native/kernel/margin in
      -- this remainder. Recheck its projection before the Word64 boundary.
      required = Runtime.positiveBytesValue (Runtime.runtimeMemoryOuterRequiredBytes runtime)
  unless
    (required >= childReserve && required - childReserve <= parentMemory && finite parentMemory)
    (Left HostExecutionParentReserveInvalid)
  let draw =
        ResourceVector
          { milli_cpu = cpu `div` 1000
          , memory_mib = (memory + 1048575) `div` 1048576
          , ephemeral_storage_mib = ephemeralStorageMib demand
          , durable_storage_mib = durableStorageMib demand
          }
  case checked of
    Allocation.SomeAllocatedPlan _ plan -> do
      remaining <-
        first
          HostExecutionOverCommitted
          (Allocation.allocate (Allocation.allocatedPlanClusterBudget plan) draw)
      pure
        ( HostExecutionPlan
            (Allocation.allocatedPlanSource plan)
            runtime
            demand
            draw
            (Allocation.clusterBudgetRemaining remaining)
            (fromIntegral parentMemory)
            (fromIntegral memory)
            (fromIntegral cpu)
            (fromIntegral tasks)
            roles
        )

transportDraw :: HostExecutionRoles topology -> (Natural, Natural, Natural)
transportDraw roles = case roles of
  HostSerialRoles -> (0, 0, 0)
  HostTransportRoles limits ->
    ( fromIntegral (hostTransportCpuUsecPerSec limits)
    , fromIntegral (hostTransportTasks limits)
    , fromIntegral (hostTransportMemoryBytes limits)
    )

hostExecutionTransportLimits :: HostExecutionTransportPlan -> HostTransportLimits
hostExecutionTransportLimits (HostExecutionPlan _ _ _ _ _ _ _ _ _ (HostTransportRoles limits)) = limits

hostExecutionSourcePlan :: HostExecutionPlanFor topology -> ResourcePlan
hostExecutionSourcePlan (HostExecutionPlan source _ _ _ _ _ _ _ _ _) = source

hostExecutionRuntimeMemory :: HostExecutionPlanFor topology -> Runtime.RuntimeMemoryPlan
hostExecutionRuntimeMemory (HostExecutionPlan _ runtime _ _ _ _ _ _ _ _) = runtime

hostExecutionDraw :: HostExecutionPlanFor topology -> ResourceVector
hostExecutionDraw (HostExecutionPlan _ _ _ draw _ _ _ _ _ _) = draw

hostExecutionRemaining :: HostExecutionPlanFor topology -> ResourceVector
hostExecutionRemaining (HostExecutionPlan _ _ _ _ remaining _ _ _ _ _) = remaining

hostExecutionParentMemoryBytes :: HostExecutionPlanFor topology -> Word64
hostExecutionParentMemoryBytes (HostExecutionPlan _ _ _ _ _ memory _ _ _ _) = memory

hostExecutionSliceMemoryBytes :: HostExecutionPlanFor topology -> Word64
hostExecutionSliceMemoryBytes (HostExecutionPlan _ _ _ _ _ _ memory _ _ _) = memory

hostExecutionSliceCpuUsecPerSec :: HostExecutionPlanFor topology -> Word64
hostExecutionSliceCpuUsecPerSec (HostExecutionPlan _ _ _ _ _ _ _ cpu _ _) = cpu

hostExecutionSliceTasks :: HostExecutionPlanFor topology -> Word64
hostExecutionSliceTasks (HostExecutionPlan _ _ _ _ _ _ _ _ tasks _) = tasks

hostExecutionChildMemoryBytes
  , hostExecutionHelperMemoryBytes
    :: HostExecutionPlanFor topology -> Word64
hostExecutionChildMemoryBytes = project childMemoryBytes
hostExecutionHelperMemoryBytes = project helperMemoryBytes

hostExecutionParentCpuUsecPerSec
  , hostExecutionChildCpuUsecPerSec
  , hostExecutionHelperCpuUsecPerSec
    :: HostExecutionPlanFor topology -> Word64
hostExecutionParentCpuUsecPerSec = project parentCpuUsecPerSec
hostExecutionChildCpuUsecPerSec = project childCpuUsecPerSec
hostExecutionHelperCpuUsecPerSec = project helperCpuUsecPerSec

hostExecutionParentTasks
  , hostExecutionChildTasks
  , hostExecutionHelperTasks
    :: HostExecutionPlanFor topology -> Word64
hostExecutionParentTasks = project parentTasks
hostExecutionChildTasks = project childTasks
hostExecutionHelperTasks = project helperTasks

hostExecutionMaximumChildMicros :: HostExecutionPlanFor topology -> Word64
hostExecutionMaximumChildMicros =
  fromIntegral
    . Runtime.childProcessDeadlineMicros
    . Runtime.runtimeMemoryChildBudget
    . hostExecutionRuntimeMemory

project :: (HostExecutionDemand -> Natural) -> HostExecutionPlanFor topology -> Word64
project field (HostExecutionPlan _ _ demand _ _ _ _ _ _ _) = fromIntegral (field demand)
