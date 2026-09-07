{-# LANGUAGE OverloadedStrings #-}

-- | Frozen live scheduler counterexample for the overlapping AWS-admin
-- Credential Provisioner and Target materializer pair.
module Prodbox.Capacity.OneShotWorkerSchedulerBudget
  ( OneShotWorkerSchedulerTopology (..)
  , OneShotWorkerSchedulerFaultSchedule (..)
  , OneShotWorkerSchedulerDisposition (..)
  , OneShotWorkerSchedulerCounterexample (..)
  , OneShotWorkerSchedulerClosure (..)
  , OneShotWorkerSchedulerCounterexampleError (..)
  , oneShotWorkerSchedulerCounterexampleId
  , frozenOneShotWorkerSchedulerCounterexample
  , validateOneShotWorkerSchedulerCounterexample
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config
  ( ResourceEnvelope (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  , WorkloadConcurrency (ExclusiveWindow)
  , WorkloadResourceProfile (..)
  , defaultResourcePlan
  , oneShotSecretWorkerEnvelope
  , oneShotSecretWorkerWindow
  , plusResourceVector
  , resources
  )
import Prodbox.Capacity.Placement (concurrentPlanDraws)

data OneShotWorkerSchedulerTopology
  = OneCredentialProvisionerParentOneTargetMaterializer
  deriving (Eq, Show)

data OneShotWorkerSchedulerFaultSchedule
  = NoInjectedOneShotWorkerFault
  deriving (Eq, Show)

data OneShotWorkerSchedulerDisposition
  = OneShotWorkerSchedulerInsufficientCpu
      { oneShotWorkerSchedulerRequiredMilliCpu :: !Natural
      , oneShotWorkerSchedulerAllocatableMilliCpu :: !Natural
      , oneShotWorkerSchedulerDeficitMilliCpu :: !Natural
      }
  | OneShotWorkerSchedulerAdmitted
      { oneShotWorkerSchedulerRequiredMilliCpu :: !Natural
      , oneShotWorkerSchedulerAllocatableMilliCpu :: !Natural
      , oneShotWorkerSchedulerHeadroomMilliCpu :: !Natural
      }
  deriving (Eq, Show)

data OneShotWorkerSchedulerCounterexample = OneShotWorkerSchedulerCounterexample
  { oneShotWorkerSchedulerIdentity :: !Text
  , oneShotWorkerSchedulerTopology :: !OneShotWorkerSchedulerTopology
  , oneShotWorkerSchedulerFaultSchedule :: !OneShotWorkerSchedulerFaultSchedule
  , oneShotWorkerSchedulerStandingRequestMilliCpu :: !Natural
  , oneShotWorkerSchedulerOverlappingWorkers :: !Natural
  , oneShotWorkerSchedulerWorkerEnvelope :: !ResourceEnvelope
  , oneShotWorkerSchedulerSupersededPlan :: !ResourcePlan
  , oneShotWorkerSchedulerReplacementPlan :: !ResourcePlan
  }
  deriving (Eq, Show)

data OneShotWorkerSchedulerClosure = OneShotWorkerSchedulerClosure
  { oneShotWorkerSchedulerOldToNewTotal
      :: !(ResourceVector, ResourceVector)
  , oneShotWorkerSchedulerSupersededDisposition
      :: !OneShotWorkerSchedulerDisposition
  , oneShotWorkerSchedulerReplacementDisposition
      :: !OneShotWorkerSchedulerDisposition
  , oneShotWorkerSchedulerOldToNewSystemdCpuBudget
      :: !(Natural, Natural)
  }
  deriving (Eq, Show)

data OneShotWorkerSchedulerCounterexampleError
  = OneShotWorkerSchedulerIdentityDrift
  | OneShotWorkerSchedulerCausalProfileDrift
  | OneShotWorkerSchedulerStandingDrawDrift
  | OneShotWorkerSchedulerEnvelopeDrift
  | OneShotWorkerSchedulerPlanShapeDrift
  | OneShotWorkerSchedulerPlanDrawDrift
  | OneShotWorkerSchedulerTotalChanged
  | OneShotWorkerSchedulerDispositionDrift
  | OneShotWorkerSchedulerSystemdCpuBudgetChanged
  deriving (Eq, Show)

oneShotWorkerSchedulerCounterexampleId :: Text
oneShotWorkerSchedulerCounterexampleId =
  "AWS-ADMIN-REVISIONED-TARGET-WORKER-INSUFFICIENT-CPU-2026-09-06"

frozenOneShotWorkerSchedulerCounterexample :: OneShotWorkerSchedulerCounterexample
frozenOneShotWorkerSchedulerCounterexample =
  OneShotWorkerSchedulerCounterexample
    { oneShotWorkerSchedulerIdentity = oneShotWorkerSchedulerCounterexampleId
    , oneShotWorkerSchedulerTopology = OneCredentialProvisionerParentOneTargetMaterializer
    , oneShotWorkerSchedulerFaultSchedule = NoInjectedOneShotWorkerFault
    , oneShotWorkerSchedulerStandingRequestMilliCpu = 7245
    , oneShotWorkerSchedulerOverlappingWorkers = 2
    , oneShotWorkerSchedulerWorkerEnvelope = oneShotSecretWorkerEnvelope
    , oneShotWorkerSchedulerSupersededPlan =
        defaultResourcePlan
          { rke2_reserved = supersededRke2Reservation
          , eviction_floor = supersededEvictionFloor
          }
    , oneShotWorkerSchedulerReplacementPlan = defaultResourcePlan
    }

validateOneShotWorkerSchedulerCounterexample
  :: OneShotWorkerSchedulerCounterexample
  -> Either
       OneShotWorkerSchedulerCounterexampleError
       OneShotWorkerSchedulerClosure
validateOneShotWorkerSchedulerCounterexample counterexample
  | oneShotWorkerSchedulerIdentity counterexample
      /= oneShotWorkerSchedulerCounterexampleId =
      Left OneShotWorkerSchedulerIdentityDrift
  | oneShotWorkerSchedulerTopology counterexample
      /= OneCredentialProvisionerParentOneTargetMaterializer
      || oneShotWorkerSchedulerFaultSchedule counterexample
        /= NoInjectedOneShotWorkerFault
      || oneShotWorkerSchedulerOverlappingWorkers counterexample /= 2 =
      Left OneShotWorkerSchedulerCausalProfileDrift
  | oneShotWorkerSchedulerStandingRequestMilliCpu counterexample /= 7245 =
      Left OneShotWorkerSchedulerStandingDrawDrift
  | oneShotWorkerSchedulerWorkerEnvelope counterexample
      /= oneShotSecretWorkerEnvelope
      || oneShotSecretWorkerEnvelope /= expectedWorkerEnvelope =
      Left OneShotWorkerSchedulerEnvelopeDrift
  | not (plansHaveExpectedShape superseded replacement) =
      Left OneShotWorkerSchedulerPlanShapeDrift
  | planDraw superseded /= expectedPlanDraw
      || planDraw replacement /= expectedPlanDraw =
      Left OneShotWorkerSchedulerPlanDrawDrift
  | supersededTotal /= expectedTotal
      || replacementTotal /= expectedTotal =
      Left OneShotWorkerSchedulerTotalChanged
  | supersededDisposition /= expectedSupersededDisposition
      || replacementDisposition /= expectedReplacementDisposition =
      Left OneShotWorkerSchedulerDispositionDrift
  | supersededSystemdCpuBudget /= 1000
      || replacementSystemdCpuBudget /= 1000 =
      Left OneShotWorkerSchedulerSystemdCpuBudgetChanged
  | otherwise =
      Right
        OneShotWorkerSchedulerClosure
          { oneShotWorkerSchedulerOldToNewTotal =
              (supersededTotal, replacementTotal)
          , oneShotWorkerSchedulerSupersededDisposition = supersededDisposition
          , oneShotWorkerSchedulerReplacementDisposition = replacementDisposition
          , oneShotWorkerSchedulerOldToNewSystemdCpuBudget =
              (supersededSystemdCpuBudget, replacementSystemdCpuBudget)
          }
 where
  superseded = oneShotWorkerSchedulerSupersededPlan counterexample
  replacement = oneShotWorkerSchedulerReplacementPlan counterexample
  workerDraw =
    oneShotWorkerSchedulerOverlappingWorkers counterexample
      * milli_cpu (request (oneShotWorkerSchedulerWorkerEnvelope counterexample))
  standing = oneShotWorkerSchedulerStandingRequestMilliCpu counterexample
  supersededDisposition = schedulerDisposition standing workerDraw superseded
  replacementDisposition = schedulerDisposition standing workerDraw replacement
  supersededTotal = topologyNormalizedTotal superseded
  replacementTotal = topologyNormalizedTotal replacement
  supersededSystemdCpuBudget = systemdCpuBudget superseded
  replacementSystemdCpuBudget = systemdCpuBudget replacement

plansHaveExpectedShape :: ResourcePlan -> ResourcePlan -> Bool
plansHaveExpectedShape superseded replacement =
  host_capacity superseded == expectedHost
    && host_capacity replacement == expectedHost
    && workload_profiles superseded == workload_profiles replacement
    && workload_profiles replacement == workload_profiles defaultResourcePlan
    && rke2_reserved superseded == supersededRke2Reservation
    && eviction_floor superseded == supersededEvictionFloor
    && rke2_reserved replacement == replacementRke2Reservation
    && eviction_floor replacement == replacementEvictionFloor
    && credentialWorkerProfileIsExact replacement

credentialWorkerProfileIsExact :: ResourcePlan -> Bool
credentialWorkerProfileIsExact plan =
  case [ profile
       | profile <- workload_profiles plan
       , profile_id profile == "credential-provisioner-secret-workers"
       ] of
    [profile] ->
      replicas profile == 2
        && surge profile == 0
        && workload_concurrency profile == ExclusiveWindow oneShotSecretWorkerWindow
        && resources profile == expectedWorkerEnvelope
    _ -> False

schedulerDisposition
  :: Natural
  -> Natural
  -> ResourcePlan
  -> OneShotWorkerSchedulerDisposition
schedulerDisposition standing workerDraw plan
  | required > allocatable =
      OneShotWorkerSchedulerInsufficientCpu required allocatable (required - allocatable)
  | otherwise =
      OneShotWorkerSchedulerAdmitted required allocatable (allocatable - required)
 where
  required = standing + workerDraw
  allocatable = milli_cpu (host_capacity plan) - milli_cpu (rke2_reserved plan)

topologyNormalizedTotal :: ResourcePlan -> ResourceVector
topologyNormalizedTotal plan =
  rke2_reserved plan
    `plusResourceVector` eviction_floor plan
    `plusResourceVector` planDraw plan

planDraw :: ResourcePlan -> ResourceVector
planDraw =
  foldl' plusResourceVector zeroVector . concurrentPlanDraws

systemdCpuBudget :: ResourcePlan -> Natural
systemdCpuBudget plan =
  milli_cpu (rke2_reserved plan) + milli_cpu (eviction_floor plan)

expectedHost :: ResourceVector
expectedHost = ResourceVector 8000 15872 100000 180000

supersededRke2Reservation :: ResourceVector
supersededRke2Reservation = ResourceVector 500 1536 9728 1024

replacementRke2Reservation :: ResourceVector
replacementRke2Reservation = ResourceVector 250 1536 9728 1024

supersededEvictionFloor :: ResourceVector
supersededEvictionFloor = ResourceVector 500 1024 10240 1024

replacementEvictionFloor :: ResourceVector
replacementEvictionFloor = ResourceVector 750 1024 10240 1024

expectedWorkerEnvelope :: ResourceEnvelope
expectedWorkerEnvelope =
  ResourceEnvelope
    { request = ResourceVector 250 256 256 0
    , limit = ResourceVector 250 256 256 0
    }

expectedPlanDraw :: ResourceVector
expectedPlanDraw = ResourceVector 6210 9984 15456 155648

expectedTotal :: ResourceVector
expectedTotal = ResourceVector 7210 12544 35424 157696

expectedSupersededDisposition :: OneShotWorkerSchedulerDisposition
expectedSupersededDisposition =
  OneShotWorkerSchedulerInsufficientCpu
    { oneShotWorkerSchedulerRequiredMilliCpu = 7745
    , oneShotWorkerSchedulerAllocatableMilliCpu = 7500
    , oneShotWorkerSchedulerDeficitMilliCpu = 245
    }

expectedReplacementDisposition :: OneShotWorkerSchedulerDisposition
expectedReplacementDisposition =
  OneShotWorkerSchedulerAdmitted
    { oneShotWorkerSchedulerRequiredMilliCpu = 7745
    , oneShotWorkerSchedulerAllocatableMilliCpu = 7750
    , oneShotWorkerSchedulerHeadroomMilliCpu = 5
    }

zeroVector :: ResourceVector
zeroVector = ResourceVector 0 0 0 0
