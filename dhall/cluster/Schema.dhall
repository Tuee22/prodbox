-- Cluster-topology schema for Sprint 1.53.
--
-- The Haskell mirror lives in Prodbox.Cluster.{Substrate,Topology,Placement}.
-- This Dhall file owns the pure topology vocabulary and contract predicates
-- that authored topology documents can import.

let WorkerSubstrate = < LinuxCpu | LinuxCuda | AppleMetal | CudaWindows >

let Residency = < InCluster | HostResident >

let residencyOf =
      \(s : WorkerSubstrate) ->
        merge
          { LinuxCpu = Residency.InCluster
          , LinuxCuda = Residency.InCluster
          , AppleMetal = Residency.HostResident
          , CudaWindows = Residency.HostResident
          }
          s

let residencyIsInCluster =
      \(r : Residency) ->
        merge { InCluster = True, HostResident = False } r

let substrateEq =
      \(left : WorkerSubstrate) ->
      \(right : WorkerSubstrate) ->
        merge
          { LinuxCpu =
              merge
                { LinuxCpu = True
                , LinuxCuda = False
                , AppleMetal = False
                , CudaWindows = False
                }
                right
          , LinuxCuda =
              merge
                { LinuxCpu = False
                , LinuxCuda = True
                , AppleMetal = False
                , CudaWindows = False
                }
                right
          , AppleMetal =
              merge
                { LinuxCpu = False
                , LinuxCuda = False
                , AppleMetal = True
                , CudaWindows = False
                }
                right
          , CudaWindows =
              merge
                { LinuxCpu = False
                , LinuxCuda = False
                , AppleMetal = False
                , CudaWindows = True
                }
                right
          }
          left

let ComputeWorker =
      { worker_substrate : WorkerSubstrate
      , manages_all_local_devices : Bool
      }

let Machine =
      { machine_id : Text
      , machine_substrate : WorkerSubstrate
      , compute_worker : ComputeWorker
      }

let KindTopology =
      { machine : Machine
      , node_count : Natural
      }

let Rke2Topology = { machines : List Machine }

let EksTopology =
      { node_group_size : Natural
      , eks_substrate : WorkerSubstrate
      }

let ClusterTopology =
      < Kind : KindTopology
      | Rke2 : Rke2Topology
      | Eks : EksTopology
      >

let workerMatchesMachine =
      \(m : Machine) ->
        substrateEq m.machine_substrate m.compute_worker.worker_substrate

let machinesOK =
      \(machines : List Machine) ->
        List/fold
          Machine
          machines
          Bool
          (\(m : Machine) -> \(ok : Bool) -> workerMatchesMachine m && ok)
          True

let rke2OK =
      \(r : Rke2Topology) ->
            if Natural/isZero (List/length Machine r.machines)
            then False
            else True
        &&  machinesOK r.machines

let eksOK =
      \(e : EksTopology) ->
        residencyIsInCluster (residencyOf e.eks_substrate)

let contractOK =
      \(topology : ClusterTopology) ->
        merge
          { Kind = \(k : KindTopology) -> workerMatchesMachine k.machine
          , Rke2 = rke2OK
          , Eks = eksOK
          }
          topology

let selfMachine =
      { machine_id = "prodbox-home"
      , machine_substrate = WorkerSubstrate.LinuxCpu
      , compute_worker =
          { worker_substrate = WorkerSubstrate.LinuxCpu
          , manages_all_local_devices = True
          }
      }

let selfTopology =
      ClusterTopology.Rke2 { machines = [ selfMachine ] : List Machine }

let selfContract =
      assert : contractOK selfTopology === True

in  { WorkerSubstrate = WorkerSubstrate
    , Residency = Residency
    , ComputeWorker = ComputeWorker
    , Machine = Machine
    , KindTopology = KindTopology
    , Rke2Topology = Rke2Topology
    , EksTopology = EksTopology
    , ClusterTopology = ClusterTopology
    , residencyOf = residencyOf
    , residencyIsInCluster = residencyIsInCluster
    , substrateEq = substrateEq
    , workerMatchesMachine = workerMatchesMachine
    , machinesOK = machinesOK
    , contractOK = contractOK
    }
