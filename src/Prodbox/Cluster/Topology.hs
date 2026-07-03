{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Cluster.Topology
  ( ClusterTopology
  , ClusterType (..)
  , ComputeWorker (..)
  , EksTopology (..)
  , KindTopology (..)
  , Machine
  , MachineId
  , Rke2Topology (..)
  , TopologyError (..)
  , clusterType
  , clusterTopologyMachines
  , clusterTopologyWorkerSubstrates
  , compute_worker
  , defaultClusterTopology
  , defaultComputeWorker
  , defaultMachine
  , machineIdText
  , machine_id
  , machine_substrate
  , mkEksTopology
  , mkMachine
  , mkMachineId
  , mkRke2Topology
  , renderClusterType
  , renderTopologyError
  , validateClusterTopology
  )
where

import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Cluster.Substrate
  ( WorkerSubstrate (..)
  , renderWorkerSubstrate
  , residencyIsInCluster
  , residencyOf
  )

newtype MachineId = MachineId {machineIdText :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromDhall, ToDhall)

data ComputeWorker = ComputeWorker
  { worker_substrate :: WorkerSubstrate
  , manages_all_local_devices :: Bool
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data Machine = Machine
  { machine_id :: MachineId
  , machine_substrate :: WorkerSubstrate
  , compute_worker :: ComputeWorker
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data KindTopology = KindTopology
  { machine :: Machine
  , node_count :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data Rke2Topology = Rke2Topology
  { machines :: [Machine]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data EksTopology = EksTopology
  { node_group_size :: Natural
  , eks_substrate :: WorkerSubstrate
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data ClusterTopology
  = Kind KindTopology
  | Rke2 Rke2Topology
  | Eks EksTopology
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data ClusterType
  = ClusterTypeKind
  | ClusterTypeRke2
  | ClusterTypeEks
  deriving (Eq, Show)

data TopologyError
  = EmptyMachineId
  | WorkerSubstrateMismatch WorkerSubstrate WorkerSubstrate
  | Rke2TopologyEmpty
  | EksHostResidentSubstrate WorkerSubstrate
  deriving (Eq, Show)

mkMachineId :: Text -> Either TopologyError MachineId
mkMachineId raw
  | Text.null (Text.strip raw) = Left EmptyMachineId
  | otherwise = Right (MachineId raw)

mkMachine :: MachineId -> WorkerSubstrate -> ComputeWorker -> Either TopologyError Machine
mkMachine mid substrate worker
  | worker_substrate worker /= substrate =
      Left (WorkerSubstrateMismatch substrate (worker_substrate worker))
  | otherwise =
      Right
        Machine
          { machine_id = mid
          , machine_substrate = substrate
          , compute_worker = worker
          }

mkRke2Topology :: NonEmpty Machine -> ClusterTopology
mkRke2Topology nonEmptyMachines =
  Rke2 Rke2Topology {machines = NonEmpty.toList nonEmptyMachines}

mkEksTopology :: Natural -> WorkerSubstrate -> Either TopologyError ClusterTopology
mkEksTopology size substrate
  | residencyIsInCluster (residencyOf substrate) =
      Right (Eks EksTopology {node_group_size = size, eks_substrate = substrate})
  | otherwise =
      Left (EksHostResidentSubstrate substrate)

clusterType :: ClusterTopology -> ClusterType
clusterType topology =
  case topology of
    Kind _ -> ClusterTypeKind
    Rke2 _ -> ClusterTypeRke2
    Eks _ -> ClusterTypeEks

clusterTopologyMachines :: ClusterTopology -> [Machine]
clusterTopologyMachines topology =
  case topology of
    Kind kindTopology -> [machine kindTopology]
    Rke2 rke2Topology -> machines rke2Topology
    Eks _ -> []

clusterTopologyWorkerSubstrates :: ClusterTopology -> [WorkerSubstrate]
clusterTopologyWorkerSubstrates topology =
  case topology of
    Kind kindTopology -> [machine_substrate (machine kindTopology)]
    Rke2 rke2Topology -> map machine_substrate (machines rke2Topology)
    Eks eksTopology -> [eks_substrate eksTopology]

renderClusterType :: ClusterType -> String
renderClusterType topologyType =
  case topologyType of
    ClusterTypeKind -> "kind"
    ClusterTypeRke2 -> "rke2"
    ClusterTypeEks -> "eks"

validateClusterTopology :: ClusterTopology -> Either TopologyError ()
validateClusterTopology topology =
  case topology of
    Kind kindTopology -> validateMachine (machine kindTopology)
    Rke2 rke2Topology ->
      case machines rke2Topology of
        [] -> Left Rke2TopologyEmpty
        first : rest -> traverse_ validateMachine (first : rest)
    Eks eksTopology ->
      if residencyIsInCluster (residencyOf (eks_substrate eksTopology))
        then Right ()
        else Left (EksHostResidentSubstrate (eks_substrate eksTopology))

validateMachine :: Machine -> Either TopologyError ()
validateMachine machineValue = do
  _ <- mkMachineId (machineIdText (machine_id machineValue))
  _ <-
    mkMachine (machine_id machineValue) (machine_substrate machineValue) (compute_worker machineValue)
  pure ()

renderTopologyError :: TopologyError -> String
renderTopologyError err =
  case err of
    EmptyMachineId ->
      "cluster_topology machine_id must be non-empty"
    WorkerSubstrateMismatch machineSubstrate workerSubstrate ->
      "cluster_topology worker substrate "
        ++ renderWorkerSubstrate workerSubstrate
        ++ " does not match machine substrate "
        ++ renderWorkerSubstrate machineSubstrate
    Rke2TopologyEmpty ->
      "cluster_topology rke2 topology must include at least one machine"
    EksHostResidentSubstrate substrate ->
      "cluster_topology eks substrate must be in-cluster, not "
        ++ renderWorkerSubstrate substrate

defaultComputeWorker :: ComputeWorker
defaultComputeWorker =
  ComputeWorker
    { worker_substrate = LinuxCpu
    , manages_all_local_devices = True
    }

defaultMachine :: Machine
defaultMachine =
  Machine
    { machine_id = MachineId "prodbox-home"
    , machine_substrate = LinuxCpu
    , compute_worker = defaultComputeWorker
    }

defaultClusterTopology :: ClusterTopology
defaultClusterTopology = mkRke2Topology (defaultMachine :| [])
