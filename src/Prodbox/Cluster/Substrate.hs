{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Prodbox.Cluster.Substrate
  ( Residency (..)
  , WorkerSubstrate (..)
  , residencyOf
  , residencyIsInCluster
  , renderWorkerSubstrate
  , workerSubstrateIsHostResident
  )
where

import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)

data WorkerSubstrate
  = LinuxCpu
  | LinuxCuda
  | AppleMetal
  | CudaWindows
  deriving (Eq, Ord, Show, Generic, FromDhall, ToDhall)

data Residency
  = InCluster
  | HostResident
  deriving (Eq, Ord, Show, Generic, FromDhall, ToDhall)

residencyOf :: WorkerSubstrate -> Residency
residencyOf substrate =
  case substrate of
    LinuxCpu -> InCluster
    LinuxCuda -> InCluster
    AppleMetal -> HostResident
    CudaWindows -> HostResident

residencyIsInCluster :: Residency -> Bool
residencyIsInCluster residency =
  case residency of
    InCluster -> True
    HostResident -> False

workerSubstrateIsHostResident :: WorkerSubstrate -> Bool
workerSubstrateIsHostResident substrate =
  not (residencyIsInCluster (residencyOf substrate))

renderWorkerSubstrate :: WorkerSubstrate -> String
renderWorkerSubstrate substrate =
  case substrate of
    LinuxCpu -> "linux-cpu"
    LinuxCuda -> "linux-cuda"
    AppleMetal -> "apple-metal"
    CudaWindows -> "cuda-windows"
