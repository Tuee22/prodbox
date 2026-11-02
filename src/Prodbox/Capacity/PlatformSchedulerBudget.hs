{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Capacity.PlatformSchedulerBudget
  ( PlatformSchedulerFamily (..)
  , PlatformSchedulerDimension (..)
  , PlatformSchedulerDemandError (..)
  , platformSchedulerFamilies
  , platformSchedulerFamilyRequests
  , minimumPlatformSchedulerRequests
  , declaredPlatformSchedulerRequests
  , validatePlatformSchedulerRequests
  , renderPlatformSchedulerDemandError
  )
where

import Numeric.Natural (Natural)
import Prodbox.Capacity.Types (ResourceVector (..))

-- These are scheduler requests from the pinned tool/provider recording, not
-- additional host reservation or claims about container containment limits.
data PlatformSchedulerFamily
  = Rke2SystemPods
  | EnvoyGatewayController
  | PublicEdgeEnvoyDataPlane
  | CertManagerController
  deriving (Eq, Ord, Show, Enum, Bounded)

data PlatformSchedulerDimension
  = PlatformSchedulerCpu
  | PlatformSchedulerMemory
  | PlatformSchedulerEphemeral
  | PlatformSchedulerDurable
  deriving (Eq, Ord, Show, Enum, Bounded)

data PlatformSchedulerDemandError
  = PlatformSchedulerDemandMissing
  | PlatformSchedulerDemandUnderdeclared !PlatformSchedulerDimension !Natural !Natural
  deriving (Eq, Show)

platformSchedulerFamilies :: [PlatformSchedulerFamily]
platformSchedulerFamilies = [minBound .. maxBound]

-- LOCAL-PLATFORM-SCHEDULER-BASELINE-OMITTED-2026-10-24 records the
-- independent Pod requests and the real scheduler's Insufficient-memory event.
platformSchedulerFamilyRequests :: PlatformSchedulerFamily -> ResourceVector
platformSchedulerFamilyRequests family = case family of
  Rke2SystemPods -> ResourceVector 1575 2520 0 0
  EnvoyGatewayController -> ResourceVector 100 256 0 0
  PublicEdgeEnvoyDataPlane -> ResourceVector 110 544 0 0
  CertManagerController -> ResourceVector 50 64 0 0

minimumPlatformSchedulerRequests :: ResourceVector
minimumPlatformSchedulerRequests =
  ResourceVector
    { milli_cpu = total milli_cpu
    , memory_mib = total memory_mib
    , ephemeral_storage_mib = total ephemeral_storage_mib
    , durable_storage_mib = total durable_storage_mib
    }
 where
  total project = sum (map (project . platformSchedulerFamilyRequests) platformSchedulerFamilies)

declaredPlatformSchedulerRequests
  :: Maybe ResourceVector -> Either PlatformSchedulerDemandError ResourceVector
declaredPlatformSchedulerRequests declared = case declared of
  Nothing -> Left PlatformSchedulerDemandMissing
  Just requests -> Right requests

validatePlatformSchedulerRequests
  :: Maybe ResourceVector -> Either PlatformSchedulerDemandError ResourceVector
validatePlatformSchedulerRequests declared = do
  requests <- declaredPlatformSchedulerRequests declared
  mapM_ (validateDimension requests) [minBound .. maxBound]
  Right requests
 where
  validateDimension requests dimension
    | actual >= required = Right ()
    | otherwise = Left (PlatformSchedulerDemandUnderdeclared dimension required actual)
   where
    project = dimensionProjection dimension
    actual = project requests
    required = project minimumPlatformSchedulerRequests

dimensionProjection :: PlatformSchedulerDimension -> ResourceVector -> Natural
dimensionProjection dimension = case dimension of
  PlatformSchedulerCpu -> milli_cpu
  PlatformSchedulerMemory -> memory_mib
  PlatformSchedulerEphemeral -> ephemeral_storage_mib
  PlatformSchedulerDurable -> durable_storage_mib

renderPlatformSchedulerDemandError :: PlatformSchedulerDemandError -> String
renderPlatformSchedulerDemandError failure = case failure of
  PlatformSchedulerDemandMissing ->
    "platform-scheduler-baseline/missing: capacity.resource_plan.platform_scheduler_requests must be declared; author the complete platform requests before reconcile, or retry the canonical test command to refresh its own harness config"
  PlatformSchedulerDemandUnderdeclared dimension required actual ->
    "platform-scheduler-baseline/underdeclared/"
      ++ dimensionName dimension
      ++ ": requires at least "
      ++ show required
      ++ ", declared "
      ++ show actual
      ++ "; author the complete platform requests before reconcile, or retry the canonical test command to refresh its own harness config"

dimensionName :: PlatformSchedulerDimension -> String
dimensionName dimension = case dimension of
  PlatformSchedulerCpu -> "cpu-milli"
  PlatformSchedulerMemory -> "memory-mib"
  PlatformSchedulerEphemeral -> "ephemeral-mib"
  PlatformSchedulerDurable -> "durable-mib"
