{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Cluster.Placement
  ( ComputeWorkerAntiAffinity (..)
  , Placement (..)
  , WorkerPlacement (..)
  , WorkerPlacementPlan (..)
  , WorkerPlacementRefusal (..)
  , computeWorkerAntiAffinity
  , computeWorkerPlacement
  , ensureMixedSubstrateAdmissible
  , workerPlacementPlan
  )
where

import Data.Set qualified as Set
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Cluster.Substrate (WorkerSubstrate)
import Prodbox.Cluster.Topology
  ( ClusterTopology
  , ClusterType (..)
  , Machine
  , MachineId
  , clusterTopologyMachines
  , clusterTopologyWorkerSubstrates
  , clusterType
  , compute_worker
  , machine_id
  , machine_substrate
  , worker_substrate
  )

data Placement
  = PlacementAdmitted MachineId
  | PlacementSubstrateMismatch WorkerSubstrate WorkerSubstrate
  | PlacementInsufficientCapacity MachineId
  deriving (Eq, Show)

data ComputeWorkerAntiAffinity = ComputeWorkerAntiAffinity
  { workerAntiAffinityTopologyKey :: Text
  , workerAntiAffinityMaxWorkersPerMachine :: Natural
  , workerRolloutMaxSurge :: Natural
  , workerRolloutMaxUnavailable :: Natural
  }
  deriving (Eq, Show)

data WorkerPlacement = WorkerPlacement
  { workerPlacementMachineId :: MachineId
  , workerPlacementSubstrate :: WorkerSubstrate
  , workerPlacementAntiAffinity :: ComputeWorkerAntiAffinity
  }
  deriving (Eq, Show)

data WorkerPlacementPlan = WorkerPlacementPlan
  { workerPlacementClusterType :: ClusterType
  , workerPlacementWorkers :: [WorkerPlacement]
  }
  deriving (Eq, Show)

data WorkerPlacementRefusal
  = WorkerPlacementDuplicateMachine MachineId
  | WorkerPlacementMixedSubstrateRejected ClusterType [WorkerSubstrate]
  | WorkerPlacementWorkerSubstrateMismatch MachineId WorkerSubstrate WorkerSubstrate
  deriving (Eq, Show)

computeWorkerAntiAffinity :: ComputeWorkerAntiAffinity
computeWorkerAntiAffinity =
  ComputeWorkerAntiAffinity
    { workerAntiAffinityTopologyKey = "kubernetes.io/hostname"
    , workerAntiAffinityMaxWorkersPerMachine = 1
    , workerRolloutMaxSurge = 0
    , workerRolloutMaxUnavailable = 1
    }

computeWorkerPlacement :: WorkerSubstrate -> Machine -> Placement
computeWorkerPlacement wantedSubstrate machine =
  if wantedSubstrate == machine_substrate machine
    then PlacementAdmitted (machine_id machine)
    else PlacementSubstrateMismatch wantedSubstrate (machine_substrate machine)

workerPlacementPlan :: ClusterTopology -> Either WorkerPlacementRefusal WorkerPlacementPlan
workerPlacementPlan topology = do
  ensureMixedSubstrateAdmissible topologyKind (clusterTopologyWorkerSubstrates topology)
  ensureNoDuplicateMachines topologyMachines
  placements <- traverse workerPlacementForMachine topologyMachines
  pure
    WorkerPlacementPlan
      { workerPlacementClusterType = topologyKind
      , workerPlacementWorkers = placements
      }
 where
  topologyKind = clusterType topology
  topologyMachines = clusterTopologyMachines topology

ensureMixedSubstrateAdmissible
  :: ClusterType
  -> [WorkerSubstrate]
  -> Either WorkerPlacementRefusal ()
ensureMixedSubstrateAdmissible topologyKind substrates =
  let distinct = Set.toList (Set.fromList substrates)
   in case (topologyKind, distinct) of
        (_, [_]) -> Right ()
        (_, []) -> Right ()
        (ClusterTypeRke2, _) -> Right ()
        _ -> Left (WorkerPlacementMixedSubstrateRejected topologyKind distinct)

ensureNoDuplicateMachines :: [Machine] -> Either WorkerPlacementRefusal ()
ensureNoDuplicateMachines machines =
  case firstDuplicate (map machine_id machines) of
    Nothing -> Right ()
    Just duplicate -> Left (WorkerPlacementDuplicateMachine duplicate)

workerPlacementForMachine :: Machine -> Either WorkerPlacementRefusal WorkerPlacement
workerPlacementForMachine machine =
  let wantedSubstrate = worker_substrate (compute_worker machine)
      actualSubstrate = machine_substrate machine
   in if wantedSubstrate == actualSubstrate
        then
          Right
            WorkerPlacement
              { workerPlacementMachineId = machine_id machine
              , workerPlacementSubstrate = actualSubstrate
              , workerPlacementAntiAffinity = computeWorkerAntiAffinity
              }
        else
          Left
            ( WorkerPlacementWorkerSubstrateMismatch
                (machine_id machine)
                wantedSubstrate
                actualSubstrate
            )

firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate values =
  go Set.empty values
 where
  go _ [] = Nothing
  go seen (value : rest)
    | value `Set.member` seen = Just value
    | otherwise = go (Set.insert value seen) rest
