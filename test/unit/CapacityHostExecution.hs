{-# LANGUAGE OverloadedStrings #-}

module CapacityHostExecution (capacityHostExecutionSuite) where

import Control.Monad (forM_)
import Data.Maybe (isJust, isNothing)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Capacity.RuntimeMemory qualified as Runtime
import Prodbox.Subprocess qualified as Subprocess
import TestSupport

capacityHostExecutionSuite :: SuiteBuilder ()
capacityHostExecutionSuite = describe "host execution budget and original window" $ do
  it "charges one shared slice and derives its parent ceiling after the child/helper reserve" $ do
    let plan = fixture (compile runtime demand)
    Host.hostExecutionSourcePlan plan `shouldBe` sourcePlan
    Host.hostExecutionRuntimeMemory plan `shouldBe` runtime
    Host.hostExecutionDraw plan `shouldBe` Capacity.ResourceVector 700 128 1 0
    Host.hostExecutionRemaining plan `shouldBe` Capacity.ResourceVector 800 3200 9187 9700
    map
      ($ plan)
      [ Host.hostExecutionParentMemoryBytes
      , Host.hostExecutionChildMemoryBytes
      , Host.hostExecutionHelperMemoryBytes
      , Host.hostExecutionSliceMemoryBytes
      ]
      `shouldBe` map (* 1048576) [48, 64, 16, 128]
    map
      ($ plan)
      [ Host.hostExecutionParentCpuUsecPerSec
      , Host.hostExecutionChildCpuUsecPerSec
      , Host.hostExecutionHelperCpuUsecPerSec
      , Host.hostExecutionSliceCpuUsecPerSec
      ]
      `shouldBe` [100000, 500000, 100000, 700000]
    map
      ($ plan)
      [ Host.hostExecutionParentTasks
      , Host.hostExecutionChildTasks
      , Host.hostExecutionHelperTasks
      , Host.hostExecutionSliceTasks
      ]
      `shouldBe` [16, 32, 8, 56]
    Host.hostExecutionMaximumChildMicros plan `shouldBe` 5000000

  it "funds persistent transport by repartitioning the same aggregate draw" $ do
    let original = fixture (compile runtime demand)
        plan = fixture (compileTransport pairedRuntime pairedDemand transportDemand)
        transport = Host.hostExecutionTransportLimits plan
    compile pairedRuntime pairedDemand `shouldBe` Left Host.HostExecutionScheduleNotSerial
    Host.hostExecutionSourcePlan plan `shouldBe` Host.hostExecutionSourcePlan original
    Host.hostExecutionDraw plan `shouldBe` Host.hostExecutionDraw original
    Host.hostExecutionRemaining plan `shouldBe` Host.hostExecutionRemaining original
    Host.hostExecutionParentMemoryBytes plan `shouldBe` Host.hostExecutionParentMemoryBytes original
    Host.hostExecutionSliceCpuUsecPerSec plan `shouldBe` Host.hostExecutionSliceCpuUsecPerSec original
    Host.hostExecutionSliceTasks plan `shouldBe` Host.hostExecutionSliceTasks original
    Host.hostExecutionMaximumChildMicros plan `shouldBe` Host.hostExecutionMaximumChildMicros original
    map
      ($ plan)
      [ Host.hostExecutionParentMemoryBytes
      , Host.hostExecutionChildMemoryBytes
      , Host.hostExecutionHelperMemoryBytes
      ]
      `shouldBe` map (* 1048576) [48, 48, 16]
    Host.hostTransportMemoryBytes transport `shouldBe` (16 * 1048576)
    Host.hostTransportTasks transport `shouldBe` 8
    Host.hostTransportCpuUsecPerSec transport `shouldBe` 100000
    fmap
      (\(commandPeak, transportPeak) -> map Runtime.positiveBytesValue [commandPeak, transportPeak])
      (Runtime.childProcessConcurrentPair (Runtime.runtimeMemoryChildBudget pairedRuntime))
      `shouldBe` Just (map (* 1048576) [64, 16])

  forM_
    [
      ( "serialized transport"
      , runtime
      , pairedDemand
      , transportDemand
      , Host.HostExecutionScheduleNotPaired
      )
    ,
      ( "three simultaneous roles"
      , pairedMemory [32, 32, 16]
      , pairedDemand
      , transportDemand
      , Host.HostExecutionScheduleNotPaired
      )
    ,
      ( "reversed role peaks"
      , pairedMemory [16, 64]
      , pairedDemand
      , transportDemand
      , Host.HostExecutionTransportPeakMismatch
      )
    ,
      ( "incorrect role peaks with the same total"
      , pairedMemory [48, 32]
      , pairedDemand
      , transportDemand
      , Host.HostExecutionTransportPeakMismatch
      )
    ,
      ( "unfunded transport"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportMemoryBytes = 17 * 1048576}
      , Host.HostExecutionChildReserveMismatch
      )
    ,
      ( "zero transport memory"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportMemoryBytes = 0}
      , Host.HostExecutionInvalidBound
      )
    ,
      ( "zero transport CPU"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportCpuUsecPerSec = 0}
      , Host.HostExecutionInvalidBound
      )
    ,
      ( "zero transport tasks"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportTasks = 0}
      , Host.HostExecutionInvalidBound
      )
    ,
      ( "unrepresentable transport CPU"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportCpuUsecPerSec = 100001}
      , Host.HostExecutionCpuGranularity
      )
    ,
      ( "infinite transport memory"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportMemoryBytes = fromIntegral (maxBound :: Word64)}
      , Host.HostExecutionInvalidBound
      )
    ,
      ( "infinite transport tasks"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportTasks = fromIntegral (maxBound :: Word64)}
      , Host.HostExecutionInvalidBound
      )
    ,
      ( "overflowing combined tasks"
      , pairedRuntime
      , pairedDemand
      , transportDemand {Host.transportTasks = fromIntegral (maxBound :: Word64) - 1}
      , Host.HostExecutionInvalidBound
      )
    ]
    $ \(label, inputs, commands, transport, expected) ->
      it ("refuses " <> label) $
        compileTransport inputs commands transport `shouldBe` Left expected

  forM_
    [ ("CPU", pairedRuntime, pairedDemand, transportDemand {Host.transportCpuUsecPerSec = 1000000})
    ,
      ( "memory"
      , memory (3329 * 1048576) (Runtime.BoundedChildSchedule 2 (Just 5000000) [64 * 1048576, 16 * 1048576])
      , pairedDemand
      , transportDemand
      )
    ,
      ( "ephemeral storage"
      , pairedRuntime
      , pairedDemand {Host.ephemeralStorageMib = 9189}
      , transportDemand
      )
    , ("durable storage", pairedRuntime, pairedDemand {Host.durableStorageMib = 9701}, transportDemand)
    ]
    $ \(label, inputs, commands, transport) ->
      it ("refuses a combined command/transport " <> label <> " draw above the host budget") $
        case compileTransport inputs commands transport of
          Left (Host.HostExecutionOverCommitted _) -> pure ()
          result -> expectationFailure ("expected combined host-budget refusal, got " <> show result)

  it "checks the observed host before admitting command and transport together" $ do
    let smaller = observed ((Capacity.host_capacity sourcePlan) {Capacity.memory_mib = 4095})
    case Host.compileHostExecutionPlanWithTransport
      smaller
      allocated
      pairedRuntime
      pairedDemand
      transportDemand of
      Left (Host.HostExecutionObservedHostRefused _) -> pure ()
      result -> expectationFailure ("expected paired observed-host refusal, got " <> show result)

  it "rounds a partial MiB upward when charging the host" $ do
    let plan = fixture (compile (memory (128 * 1048576 + 1) serial) demand)
    Host.hostExecutionParentMemoryBytes plan `shouldBe` (48 * 1048576 + 1)
    Host.hostExecutionDraw plan `shouldBe` Capacity.ResourceVector 700 129 1 0
    Capacity.memory_mib (Host.hostExecutionRemaining plan) `shouldBe` 3199

  forM_
    [ ("zero CPU", runtime, demand {Host.parentCpuUsecPerSec = 0}, Host.HostExecutionInvalidBound)
    ,
      ( "unrepresentable CPU granularity"
      , runtime
      , demand {Host.childCpuUsecPerSec = 500001}
      , Host.HostExecutionCpuGranularity
      )
    ,
      ( "unfunded helper"
      , runtime
      , demand {Host.helperMemoryBytes = 17 * 1048576}
      , Host.HostExecutionChildReserveMismatch
      )
    ,
      ( "two child permits"
      , memory (128 * 1048576) (Runtime.BoundedChildSchedule 2 (Just 5000000) [40 * 1048576, 40 * 1048576])
      , demand
      , Host.HostExecutionScheduleNotSerial
      )
    ,
      ( "infinite wire task bound"
      , runtime
      , demand {Host.parentTasks = fromIntegral (maxBound :: Word64)}
      , Host.HostExecutionInvalidBound
      )
    ,
      ( "overflowing aggregate task bound"
      , runtime
      , demand {Host.parentTasks = fromIntegral (maxBound :: Word64) - 1}
      , Host.HostExecutionInvalidBound
      )
    , ("zero child memory", runtime, demand {Host.childMemoryBytes = 0}, Host.HostExecutionInvalidBound)
    , ("zero helper tasks", runtime, demand {Host.helperTasks = 0}, Host.HostExecutionInvalidBound)
    ]
    $ \(label, inputs, requested, expected) ->
      it ("refuses " <> label) $
        compile inputs requested `shouldBe` Left expected

  forM_
    [ ("CPU", runtime, demand {Host.childCpuUsecPerSec = 1500000})
    , ("memory", memory (3329 * 1048576) serial, demand)
    , ("ephemeral storage", runtime, demand {Host.ephemeralStorageMib = 9189})
    , ("durable storage", runtime, demand {Host.durableStorageMib = 9701})
    ]
    $ \(label, inputs, requested) ->
      it ("refuses an aggregate " <> label <> " draw above the remaining host budget") $
        case compile inputs requested of
          Left (Host.HostExecutionOverCommitted _) -> pure ()
          result -> expectationFailure ("expected host-budget refusal, got " <> show result)

  it "checks the actual host before spending its declared budget" $ do
    let smaller = observed ((Capacity.host_capacity sourcePlan) {Capacity.milli_cpu = 1999})
    case Host.compileHostExecutionPlan smaller allocated runtime demand of
      Left (Host.HostExecutionObservedHostRefused _) -> pure ()
      result -> expectationFailure ("expected observed-host refusal, got " <> show result)

  it "accepts one bounded recoverable key and refuses malformed or unbounded keys" $ do
    Subprocess.hostExecutionKeyFromText (replicate 64 'a') `shouldSatisfy` isJust
    forM_
      ["", replicate 32 'a', replicate 65 'a', replicate 64 'A', replicate 63 'a' <> "g", repeat 'a']
      $ \key ->
        Subprocess.hostExecutionKeyFromText key `shouldSatisfy` isNothing

  it "requires five finite strictly ordered absolute ends" $ do
    Subprocess.hostExecutionWindow 1000 100 200 300 400 `shouldSatisfy` isJust
    forM_
      [ (1000, 0, 200, 300, 400)
      , (1000, 200, 200, 300, 400)
      , (1000, 100, 300, 300, 400)
      , (1000, 100, 200, 400, 400)
      , (400, 100, 200, 300, 400)
      , (maxBound, 100, 200, 300, 400)
      ]
      $ \(outer, work, hard, stop, finish) ->
        Subprocess.hostExecutionWindow outer work hard stop finish `shouldBe` Nothing

fixture :: (Show error) => Either error value -> value
fixture = either (error . ("invalid host-execution unit fixture: " <>) . show) id

sourcePlan :: Capacity.ResourcePlan
sourcePlan =
  Capacity.defaultResourcePlan
    { Capacity.host_capacity = Capacity.ResourceVector 2000 4096 10000 10000
    , Capacity.rke2_reserved = Capacity.ResourceVector 100 128 100 100
    , Capacity.eviction_floor = Capacity.ResourceVector 100 128 100 100
    , Capacity.platform_scheduler_requests = Just (Capacity.ResourceVector 200 256 100 100)
    , Capacity.workload_profiles =
        filter
          ((== "redis") . Capacity.profile_id)
          (Capacity.workload_profiles Capacity.defaultResourcePlan)
    }

allocated :: Allocation.SomeAllocatedPlan
allocated = fixture (Allocation.compileResourcePlanUncertified sourcePlan)

observed :: Capacity.ResourceVector -> Observed.ObservedHostRoot
observed capacity =
  fixture $
    Observed.mkObservedHostRoot
      capacity
      (maybe (error "invalid unit ephemeral device") id (Observed.mkStorageDeviceId "unit-ephemeral"))
      (maybe (error "invalid unit durable device") id (Observed.mkStorageDeviceId "unit-durable"))

compile
  :: Runtime.RuntimeMemoryPlan
  -> Host.HostExecutionDemand
  -> Either Host.HostExecutionError Host.HostExecutionPlan
compile = Host.compileHostExecutionPlan (observed (Capacity.host_capacity sourcePlan)) allocated

compileTransport
  :: Runtime.RuntimeMemoryPlan
  -> Host.HostExecutionDemand
  -> Host.HostTransportDemand
  -> Either Host.HostExecutionError Host.HostExecutionTransportPlan
compileTransport =
  Host.compileHostExecutionPlanWithTransport (observed (Capacity.host_capacity sourcePlan)) allocated

demand :: Host.HostExecutionDemand
demand = Host.HostExecutionDemand 100000 500000 100000 16 32 8 (64 * 1048576) (16 * 1048576) 1 0

-- Arithmetic fixture only: repartition the original command allowance.
-- These are neither measured kubectl/Helm peaks nor a production profile.
pairedDemand :: Host.HostExecutionDemand
pairedDemand =
  demand
    { Host.childCpuUsecPerSec = 400000
    , Host.childTasks = 24
    , Host.childMemoryBytes = 48 * 1048576
    }

transportDemand :: Host.HostTransportDemand
transportDemand = Host.HostTransportDemand 100000 8 (16 * 1048576)

pairedRuntime :: Runtime.RuntimeMemoryPlan
pairedRuntime = pairedMemory [64, 16]

pairedMemory :: [Natural] -> Runtime.RuntimeMemoryPlan
pairedMemory peaks =
  memory
    (128 * 1048576)
    (Runtime.BoundedChildSchedule (fromIntegral (length peaks)) (Just 5000000) (map (* 1048576) peaks))

serial :: Runtime.RawChildSchedule
serial = Runtime.BoundedChildSchedule 1 (Just 5000000) [80 * 1048576]

runtime :: Runtime.RuntimeMemoryPlan
runtime = memory (128 * 1048576) serial

memory :: Natural -> Runtime.RawChildSchedule -> Runtime.RuntimeMemoryPlan
memory outer schedule =
  fixture $
    Runtime.validateRuntimeMemoryPlan
      Runtime.RuntimeMemoryInputs
        { Runtime.runtimeBoundedApplicationState = bytes Runtime.BoundedApplicationState 2
        , Runtime.runtimeBoundedPendingPersistenceState = bytes Runtime.BoundedPendingPersistenceState 1
        , Runtime.runtimeInHeapTransportDecodeScratch = bytes Runtime.InHeapTransportDecodeScratch 3
        , Runtime.runtimeOtherHeapReserve = bytes Runtime.OtherHeapReserve 2
        , Runtime.runtimeHeapCap = bytes Runtime.HeapCap 8
        , Runtime.runtimeNativeNonHeapReserve = bytes Runtime.NativeNonHeapReserve 8
        , Runtime.runtimeRawChildSchedule = schedule
        , Runtime.runtimeKernelCgroupReserve = bytes Runtime.KernelCgroupReserve 4
        , Runtime.runtimeSafetyMargin = bytes Runtime.SafetyMargin 4
        , Runtime.runtimeContainerMemoryLimit =
            fixture (Runtime.mkPositiveBytes Runtime.ContainerMemoryLimit outer)
        }
 where
  bytes term count = fixture (Runtime.mkPositiveBytes term (count * 1048576))
