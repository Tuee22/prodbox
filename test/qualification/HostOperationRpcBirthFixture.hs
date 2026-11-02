{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Native-only normalized 256 MiB / 700m / 56-task profile. The launch process
-- observes the real host once; the controller receives that fixed metadata.
module HostOperationRpcBirthFixture (fixturePlan, fixturePlanFrom, observedValue, decodeObserved, right) where

import Data.Aeson (Value, eitherDecode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as Lazy
import Prodbox.Capacity.Allocation qualified as A
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.HostExecution qualified as H
import Prodbox.Capacity.HostProbe qualified as Probe
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Capacity.RuntimeMemory qualified as R
import System.Environment (unsetEnv)

right :: (Show error) => Either error value -> IO value
right = either (fail . show) pure

fixturePlan :: IO (H.HostExecutionTransportPlan, Observed.ObservedHostRoot)
fixturePlan = do
  unsetEnv "PRODBOX_TEST_HOST_CAPACITY"
  observed <-
    right =<< Probe.observeHostCapacity "/home/matthewnowak/prodbox" "/home/matthewnowak/prodbox"
  plan <- fixturePlanFrom observed
  pure (plan, observed)

fixturePlanFrom
  :: Observed.ObservedHostRoot
  -> IO H.HostExecutionTransportPlan
fixturePlanFrom observed = do
  let base = C.defaultResourcePlan
      isolated =
        base
          { C.host_capacity = C.ResourceVector 2000 4096 8192 8192
          , C.rke2_reserved = C.ResourceVector 100 128 256 1
          , C.eviction_floor = C.ResourceVector 100 128 256 1
          , C.platform_scheduler_requests = Just (C.ResourceVector 0 0 0 0)
          , C.workload_profiles = filter ((== "redis") . C.profile_id) (C.workload_profiles base)
          }
      bytes term count = either (error . show) id (R.mkPositiveBytes term (count * 1048576))
  allocated <- right (A.compileResourcePlanUncertified isolated)
  runtime <-
    right $
      R.validateRuntimeMemoryPlan
        R.RuntimeMemoryInputs
          { R.runtimeBoundedApplicationState = bytes R.BoundedApplicationState 2
          , R.runtimeBoundedPendingPersistenceState = bytes R.BoundedPendingPersistenceState 1
          , R.runtimeInHeapTransportDecodeScratch = bytes R.InHeapTransportDecodeScratch 3
          , R.runtimeOtherHeapReserve = bytes R.OtherHeapReserve 2
          , R.runtimeHeapCap = bytes R.HeapCap 128
          , R.runtimeNativeNonHeapReserve = bytes R.NativeNonHeapReserve 32
          , R.runtimeRawChildSchedule = R.BoundedChildSchedule 2 (Just 60000000) [64 * 1048576, 16 * 1048576]
          , R.runtimeKernelCgroupReserve = bytes R.KernelCgroupReserve 8
          , R.runtimeSafetyMargin = bytes R.SafetyMargin 8
          , R.runtimeContainerMemoryLimit = bytes R.ContainerMemoryLimit 256
          }
  right $
    H.compileHostExecutionPlanWithTransport
      observed
      allocated
      runtime
      (H.HostExecutionDemand 300000 200000 100000 16 24 8 (48 * 1048576) (16 * 1048576) 1 0)
      (H.HostTransportDemand 100000 8 (16 * 1048576))

observedValue :: Observed.ObservedHostRoot -> Value
observedValue observed =
  object
    [ "milli_cpu" .= C.milli_cpu vector
    , "memory_mib" .= C.memory_mib vector
    , "ephemeral_storage_mib" .= C.ephemeral_storage_mib vector
    , "durable_storage_mib" .= C.durable_storage_mib vector
    , "ephemeral_device" .= Observed.storageDeviceIdText (Observed.observedEphemeralDevice observed)
    , "durable_device" .= Observed.storageDeviceIdText (Observed.observedDurableDevice observed)
    ]
 where
  vector = Observed.observedHostVector observed

decodeObserved :: Lazy.ByteString -> Either String Observed.ObservedHostRoot
decodeObserved bytes = do
  value <- eitherDecode bytes
  parseEither
    ( withObject "observed native fixture host" $ \payload -> do
        vector <-
          C.ResourceVector
            <$> payload .: "milli_cpu"
            <*> payload .: "memory_mib"
            <*> payload .: "ephemeral_storage_mib"
            <*> payload .: "durable_storage_mib"
        ephemeralText <- payload .: "ephemeral_device"
        durableText <- payload .: "durable_device"
        ephemeral <-
          maybe (fail "invalid ephemeral fixture device") pure (Observed.mkStorageDeviceId ephemeralText)
        durable <-
          maybe (fail "invalid durable fixture device") pure (Observed.mkStorageDeviceId durableText)
        either fail pure (Observed.mkObservedHostRoot vector ephemeral durable)
    )
    value
