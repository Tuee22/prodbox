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
  , eksNodeGroupSize
  , compute_worker
  , defaultClusterTopology
  , defaultComputeWorker
  , defaultMachine
  , unconfiguredClusterTopology
  , machineIdText
  , machine_id
  , machine_substrate
  , mkEksTopology
  , mkMachine
  , mkMachineId
  , mkRke2Topology
  , mkSingleMachineRke2Topology
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
import Dhall
  ( Decoder (..)
  , FromDhall (..)
  , ToDhall
  , constructor
  , extractError
  , field
  , record
  , union
  )
import Dhall.Marshal.Decode (fromMonadic, toMonadic)
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
  deriving newtype (ToDhall)

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
  deriving (Eq, Show, Generic, ToDhall)

data KindTopology = KindTopology
  { machine :: Machine
  , node_count :: Natural
  }
  deriving (Eq, Show, Generic, ToDhall)

data Rke2Topology = Rke2Topology
  { machines :: [Machine]
  }
  deriving (Eq, Show, Generic, ToDhall)

data EksTopology = EksTopology
  { node_group_size :: Natural
  , eks_substrate :: WorkerSubstrate
  }
  deriving (Eq, Show, Generic, ToDhall)

data ClusterTopology
  = Kind KindTopology
  | Rke2 Rke2Topology
  | Eks EksTopology
  deriving (Eq, Show, Generic, ToDhall)

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
  | EksNodeGroupSizeZero
  deriving (Eq, Show)

-- | Sprint 1.86: run a decoder's result through a smart constructor, so a Dhall
-- value that the constructor would reject fails the __decode__ rather than
-- producing a value the type claims cannot exist.
--
-- Before this sprint 'MachineId', 'Machine', and 'ClusterTopology' were
-- exported abstractly to force their smart constructors and also derived
-- @FromDhall@ — so decode was a second, unchecked constructor and the opacity
-- stopped at the decode seam. That is the conversion class
-- [chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md)
-- names: a typed guarantee handed across a boundary that does not honour it.
--
-- The ledger row proposed a @Raw*@ DTO narrowed after decode, the shape
-- 'Prodbox.ControlPlane.Capacity' uses. Measured, that shape cascades: the
-- decoded field lives on @ProdboxParameters@ and @ConfigFile@, both of which
-- derive @FromDhall@ generically, so removing the instance forces a parallel
-- @Raw@ record for each of them. A validating decoder puts the narrowing at the
-- same seam with none of that cascade, and is strictly stronger than a
-- post-decode check because there is no window in which the wide value exists.
narrowingDecoder :: Decoder a -> (a -> Either TopologyError b) -> Decoder b
narrowingDecoder base narrow =
  base
    { extract = \expression -> fromMonadic $ do
        wide <- toMonadic (extract base expression)
        case narrow wide of
          Right narrowed -> pure narrowed
          Left err -> toMonadic (extractError (Text.pack (renderTopologyError err)))
    }

instance FromDhall MachineId where
  autoWith options = narrowingDecoder (autoWith options) mkMachineId

instance FromDhall Machine where
  autoWith options =
    narrowingDecoder
      ( record
          ( (,,)
              <$> field "machine_id" (autoWith options)
              <*> field "machine_substrate" (autoWith options)
              <*> field "compute_worker" (autoWith options)
          )
      )
      narrowMachine

-- | Sprint 1.86: 'mkMachine' rule f, reached at the decode seam.
narrowMachine :: (MachineId, WorkerSubstrate, ComputeWorker) -> Either TopologyError Machine
narrowMachine (identifier, substrate, worker) = mkMachine identifier substrate worker

instance FromDhall KindTopology where
  autoWith options =
    record
      ( KindTopology
          <$> field "machine" (autoWith options)
          <*> field "node_count" (autoWith options)
      )

instance FromDhall Rke2Topology where
  autoWith options =
    narrowingDecoder (record (field "machines" (autoWith options))) narrowRke2Machines

-- | Sprint 1.86: an rke2 topology needs at least one machine, which is what
-- 'validateClusterTopology' checked after the fact and the decoder now enforces.
narrowRke2Machines :: [Machine] -> Either TopologyError Rke2Topology
narrowRke2Machines decoded = case decoded of
  [] -> Left Rke2TopologyEmpty
  _ -> Right Rke2Topology {machines = decoded}

instance FromDhall EksTopology where
  autoWith options =
    narrowingDecoder
      ( record
          ( (,)
              <$> field "node_group_size" (autoWith options)
              <*> field "eks_substrate" (autoWith options)
          )
      )
      narrowEksTopology

-- | Sprint 1.86: the same in-cluster-residency rule 'mkEksTopology' applies,
-- reached at the decode seam instead of only through the constructor.
narrowEksTopology :: (Natural, WorkerSubstrate) -> Either TopologyError EksTopology
narrowEksTopology (size, substrate)
  | size == 0 = Left EksNodeGroupSizeZero
  | residencyIsInCluster (residencyOf substrate) =
      Right EksTopology {node_group_size = size, eks_substrate = substrate}
  | otherwise = Left (EksHostResidentSubstrate substrate)

instance FromDhall ClusterTopology where
  autoWith options =
    union
      ( (Kind <$> constructor "Kind" (autoWith options))
          <> (Rke2 <$> constructor "Rke2" (autoWith options))
          <> (Eks <$> constructor "Eks" (autoWith options))
      )

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

-- | Build the single-machine home topology authored by @config setup@. The
-- machine identity crosses the same smart constructors as a decoded topology;
-- no compiled production identity participates.
mkSingleMachineRke2Topology :: Text -> Either TopologyError ClusterTopology
mkSingleMachineRke2Topology rawMachineId = do
  identifier <- mkMachineId rawMachineId
  configuredMachine <- mkMachine identifier LinuxCpu defaultComputeWorker
  Right (mkRke2Topology (configuredMachine :| []))

mkEksTopology :: Natural -> WorkerSubstrate -> Either TopologyError ClusterTopology
mkEksTopology size substrate
  | size == 0 = Left EksNodeGroupSizeZero
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

-- | The authored EKS desired node count when this topology names EKS.
eksNodeGroupSize :: ClusterTopology -> Maybe Natural
eksNodeGroupSize topology = case topology of
  Eks eksTopology -> Just (node_group_size eksTopology)
  _ -> Nothing

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
    Eks eksTopology
      | node_group_size eksTopology == 0 -> Left EksNodeGroupSizeZero
      | residencyIsInCluster (residencyOf (eks_substrate eksTopology)) -> Right ()
      | otherwise -> Left (EksHostResidentSubstrate (eks_substrate eksTopology))

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
    EksNodeGroupSizeZero ->
      "cluster_topology eks node_group_size must be greater than zero"

defaultComputeWorker :: ComputeWorker
defaultComputeWorker =
  ComputeWorker
    { worker_substrate = LinuxCpu
    , manages_all_local_devices = True
    }

-- | Synthetic machine used by test-topology defaults and placement fixtures.
-- Production Tier-0 generation uses 'unconfiguredClusterTopology' and never
-- inherits this identity.
defaultMachine :: Machine
defaultMachine =
  Machine
    { machine_id = MachineId "synthetic-test-machine"
    , machine_substrate = LinuxCpu
    , compute_worker = defaultComputeWorker
    }

defaultClusterTopology :: ClusterTopology
defaultClusterTopology = mkRke2Topology (defaultMachine :| [])

-- | Raw authoring skeleton for production Tier-0. The empty machine id is
-- intentionally not accepted by the validating Dhall decoder: an operator or
-- harness must author a deployment identity before the config can be used.
unconfiguredClusterTopology :: ClusterTopology
unconfiguredClusterTopology =
  mkRke2Topology
    ( defaultMachine
        { machine_id = MachineId ""
        }
        :| []
    )
