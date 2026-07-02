# Cluster Topology Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/substrates.md, documents/engineering/host_platform_doctrine.md, documents/engineering/resource_scaling_doctrine.md
**Generated sections**: none

> **Purpose**: Single Source of Truth for prodbox cluster topology — the three explicit cluster
> types (`kind` / `rke2` / `eks`), the substrate-indexed one-compute-worker-per-machine rule, and
> the type shapes that make an ill-formed topology unrepresentable rather than merely rejected.

> **Scheduling honesty.** This is present-tense declarative doctrine; the Dhall schema and Haskell
> types are **scheduled**, not built. The schema lands in
> [Phase 1 Sprint 1.53](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md) (cluster-type /
> topology / worker Dhall schema — rules c/d/e/f/i); substrate-typed placement, one-per-machine
> anti-affinity, and mixed-substrate-only-rke2 enforcement land in
> [Phase 4 Sprint 4.38](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md). Status is owned
> only by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 1. The three cluster types are explicit, never inferred

prodbox is the proven single-node **root control-plane** specialization of the ~/amoebius umbrella
(whose `.dhall` DSL makes illegal cluster state unrepresentable). A prodbox topology names its
**cluster type** — the bring-up mechanism — from a closed set of exactly three. The type is a
declared field of the in-force config ([config_doctrine.md](./config_doctrine.md)); it is **never**
detected from the host or defaulted:

| Cluster type | Bring-up | Node ↔ machine | prodbox reality |
|---|---|---|---|
| `kind` | container nodes inside one Docker host | many nodes, **one** machine | forward-looking (admin-laptop root, per the umbrella) |
| `rke2` | one RKE2 node per Linux machine | **1:1** node ↔ machine | the home-local substrate (single-node today) |
| `eks` | cloud-managed EC2 node group | cloud nodes, **no host** access | the AWS substrate |

This is the prodbox reading of the umbrella's two-kind lifecycle (self-managed `kind`/`rke2` vs
provider-managed `eks`; see amoebius `cluster_lifecycle_doctrine.md` + `substrate_doctrine.md`) and
mirrors — in kind, no code dependency — the per-substrate cluster shapes and one-worker-per-node
placement proven in jitML `cluster_topology.md`. prodbox's existing `home-local | aws` axis
([substrates.md](../../DEVELOPMENT_PLAN/substrates.md)) is the *cluster-hosting* axis: `home-local`
is a single-node `rke2` cluster, `aws` is an `eks` cluster. The **worker substrate** axis (below) is
orthogonal to it.

```dhall
-- Example: cluster-type and worker-substrate closed unions (scheduled dhall/ClusterTopologySchema.dhall)
let ClusterType = < Kind | Rke2 | Eks >

let WorkerSubstrate =
      < LinuxCpu      -- in-cluster compute worker
      | LinuxCuda     -- in-cluster compute worker (NVIDIA container runtime)
      | AppleMetal    -- host-resident worker (unified memory; not containerizable)
      | CudaWindows   -- host-resident worker (CUDA under WSL2 is not performant)
      >

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
```

The canonical schema is the **scheduled code artifact** `dhall/ClusterTopologySchema.dhall` (a
rendered-constant anti-drift mirror of a Haskell module, as jitML pairs `dhall/project/Schema.dhall`
with `JitML.Project.Config`). This doc describes facets and shows teaching fragments; it is **not**
the schema SSoT.

**The worker substrate axis (imported from jitML).** Each machine that carries compute runs exactly
**one** substrate-indexed worker. Two substrates are in-cluster (`LinuxCpu`, `LinuxCuda`); two are
host-resident because their hardware refuses to be contained — Apple Metal needs Apple-Silicon unified
memory, CUDA under WSL2 is not performant. Host-resident workers are owned by
[host_platform_doctrine.md](./host_platform_doctrine.md); this doc owns only *which substrate is
which and that the worker is substrate-typed*.

## 2. Illegal topologies are unrepresentable, not rejected

The house technique is to prefer the type that cannot express the illegal state over a validator
that rejects it ([pure_fp_standards.md → GADT-Indexed State Machines / Plan/Apply](./pure_fp_standards.md#gadt-indexed-state-machines)).
Cluster shape is decoded-from-config, not an in-process state machine, so it is a **closed ADT with
typed newtype smart constructors** plus a Dhall `assert : contractOK self === True` for the
relational invariants Dhall cannot type structurally (mirroring jitML). Each rule below is made
impossible by *shape* where possible, and by *assert* only where shape cannot reach it.

| Rule | Illegal state | Made impossible by |
|---|---|---|
| **c** | multi-node `rke2` on a single machine | `Rke2` carries `NonEmpty Machine`; an rke2 node *is* a machine — there is no separate node count to inflate, so N nodes require N machines |
| **d** | multi-node `kind` across machines | `Kind` carries a single `Machine`; kind nodes are containers *inside* it — there is no machine list to spread across |
| **e** | more than one compute worker per machine | `Machine.computeWorker` is one field, not a list — a second worker is unconstructible |
| **f** | a worker for the wrong substrate | `mkMachine` / `contractOK` require `workerSubstrate == machineSubstrate` |
| **i** | mixed-substrate `kind`/`eks`; wrong-substrate placement | only the `Rke2` arm is substrate-plural; `Kind`/`Eks` are single-substrate by shape; placement is the `Placement` projection (capacity half → [resource_scaling_doctrine.md](./resource_scaling_doctrine.md)) |

### 2.1 Structural shape (rules c, d, e, i)

```haskell
-- Example: exactly one substrate-typed worker per machine (rules e, f)
newtype MachineId = MachineId Text deriving (Eq, Show)   -- constructor unexported; smart-constructed

data ComputeWorker = ComputeWorker
  { workerSubstrate        :: WorkerSubstrate
  , managesAllLocalDevices :: Bool           -- the single worker owns EVERY local device (all GPUs)
  }
  deriving (Eq, Show)

data Machine = Machine
  { machineId        :: MachineId
  , machineSubstrate :: WorkerSubstrate
  , computeWorker    :: ComputeWorker         -- singular field: a second worker is unrepresentable (rule e)
  }
  deriving (Eq, Show)

-- Example: cluster indexed by bring-up type (rules c, d, i are structural)
data Cluster
  = ClusterKind Machine KindNodeCount               -- exactly ONE host machine (rule d)
  | ClusterRke2 (NonEmpty Machine)                  -- one rke2 node per machine (rule c)
  | ClusterEks  EksNodeGroupSize WorkerSubstrate    -- cloud EC2, no host machine; single-substrate (rule i)
  deriving (Eq, Show)
```

`ClusterKind` names one `Machine`, so a cross-machine kind cluster (rule d) has nowhere to put a
second machine. `ClusterRke2` names `NonEmpty Machine` and nothing else — an rke2 node *is* a
machine, so a single-node cluster is `length 1` (the home reality) and a multi-node cluster is a list
of distinct machines (rule c); there is no scalar node count to inflate past the machine set.
**MixedSubstrate is admissible only for `rke2`**: only the `Rke2` arm is substrate-plural, so a
mixed-substrate kind or eks cluster (rule i) is unconstructible.

### 2.2 Assert-carried relational invariants (rules f, i)

Dhall lacks built-in union equality, so the static invariants ride on `assert`, exactly as jitML's
`dhall/project/Schema.dhall` carries its budget lemma. Rule f (worker substrate matches its machine)
is enforced by a Haskell smart constructor — an ill-typed `Machine` cannot be built:

```haskell
-- Example: rule f as a smart constructor (mirrors jitML's mkAbsExe / prodbox newtype constructors)
data TopologyError = WorkerSubstrateMismatch WorkerSubstrate WorkerSubstrate  -- machine vs worker
  deriving (Eq, Show)

mkMachine :: MachineId -> WorkerSubstrate -> ComputeWorker -> Either TopologyError Machine
mkMachine mid sub w
  | workerSubstrate w /= sub = Left (WorkerSubstrateMismatch sub (workerSubstrate w))  -- rule f
  | otherwise                = Right (Machine mid sub w)
```

The Dhall `contractOK` mirrors it (`substrateEq` is a nested-merge comparator) and adds rule i for
EKS, then the generated `prodbox` topology closes with the lemma so an ill-typed topology fails
`dhall type`:

```dhall
-- Example: the static topology lemma (rule f per machine + rule i: EKS has no host-resident worker)
let workerMatchesMachine = \(m : Machine) -> substrateEq m.machineSubstrate m.computeWorker.workerSubstrate
let eksIsInCluster =
      \(e : EksCluster) -> merge { InCluster = True, HostResident = False } (residencyOf e.eksSubstrate)
let _ = assert : contractOK self === True   -- inlined beside the topology data in the generated config
```

### 2.3 Placement is a substrate-and-capacity-typed projection (rule i)

Taints and anti-affinity must never land a workload on a node of the wrong substrate or with too
little room. Placement is a **pure projection** whose "cannot admit" outcomes are explicit — the same
honesty as `ResidueStatus` (`src/Prodbox/Lifecycle/ResidueStatus.hs`) and the gateway `Disposition`
(`src/Prodbox/Gateway/Types.hs`) — never a silent "it fit":

```haskell
-- Example: substrate-and-capacity-typed placement (rule i); models "cannot admit" explicitly
data Placement
  = PlacementAdmitted MachineId                                -- substrate matches AND capacity fits
  | PlacementSubstrateMismatch WorkerSubstrate WorkerSubstrate  -- wanted vs node substrate (rule f/i)
  | PlacementInsufficientCapacity MachineId                    -- the capacity half is deferred, below
  deriving (Eq, Show)
```

The **substrate** half of rule i lives here. The **capacity** half (the `⊆` check that a workload's
requests fit the node's headroom) is owned by
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md); this projection names the outcome
constructor and defers the arithmetic.

## 3. One compute worker per machine — the runtime enforcement (rule e)

Rule e is a shape invariant at config time (§2.1) and a Kubernetes placement invariant at runtime.
The runtime half mirrors jitML's compute-scope anti-affinity exactly: the compute worker is pinned by
required pod anti-affinity at `topologyKey: kubernetes.io/hostname` and rolled out with `maxSurge: 0`
(and `maxUnavailable: 1`), so a rolling update can **never transiently** place a second worker on a
node.

Because the single worker `managesAllLocalDevices`, a machine with several GPUs is still exactly one
worker — capacity, not cardinality, scales with device count. Non-compute platform replicas (gateway,
Keycloak, and the rest of the shared inventory in
[substrates.md](../../DEVELOPMENT_PLAN/substrates.md)) scale independently and add no compute
workers.

## 4. Storage discipline and the per-worker JIT budget

Storage stays **no-provisioner** on every substrate: every PV is a manually-defined
`manual`-StorageClass volume, no dynamic provisioning anywhere. On the home substrate the PV
volume source is a `hostPath` under `.data/`; on the AWS/EKS substrate it is a pre-created EBS
volume lifted in as a static `Retain` PV (CSI `volumeHandle`), pinned to its availability zone
(Sprint `7.28`). AZ placement of an EBS-backed PV is a topology concern owned here — a static
EBS volume is AZ-bound, so its PV carries `topology.ebs.csi.aws.com/zone` affinity and its
workload schedules to a node in that zone. This doctrine does not restate the storage rules
themselves; they are owned by
[storage_lifecycle_doctrine.md § 1](./storage_lifecycle_doctrine.md#1-canonical-doctrine-statements).
Every substrate-typed compute worker additionally carries an **explicit** ML JIT-artifact + model-cache
storage budget on both host and cluster, per
[tiered_storage_capacity_doctrine.md rule k](./tiered_storage_capacity_doctrine.md#rule-k--every-ml-engine-carries-an-explicit-jit--model-cache-budget)
— a per-worker budget is mandatory, not implicit.

## 5. Bring-up is a reconcile toward the declared topology

A topology is brought up by the same `discover → diff → enact → re-observe` reconciler every prodbox
lifecycle command composes ([lifecycle_reconciliation_doctrine.md § 3](./lifecycle_reconciliation_doctrine.md));
there is no topology state machine, and re-running bring-up on a converged cluster is a no-op.
Multi-node `rke2` (rule c) provisions each additional Linux machine — where a root cluster grows
downstream nodes and the Vault transit-seal trust tree of
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md) applies — but that trust
relationship is orthogonal to the topology *shape* this document types.

## Intent Ownership

This SSoT owns the prodbox cluster-topology intention: the three explicit cluster types, the
substrate-indexed one-compute-worker-per-machine rule, and the type shapes that make rules c/d/e/f/i
unrepresentable rather than merely validated.

- Owned statement: a prodbox cluster's type (`kind`/`rke2`/`eks`) and its per-machine substrate-typed
  compute worker are declared, never inferred, and every ill-formed topology (multi-node rke2 on one
  machine, cross-machine kind, >1 worker per machine, a wrong-substrate worker, a mixed-substrate
  kind/eks cluster) is made unconstructible by type.
- Linked dependents (scheduled): `src/Prodbox/Cluster/Topology.hs` (the `Cluster` / `Machine` /
  `ComputeWorker` ADT + `mkMachine` smart constructor), `src/Prodbox/Cluster/Substrate.hs` (the
  `WorkerSubstrate` closed union + `residencyOf` projection), `src/Prodbox/Cluster/Placement.hs` (the
  `Placement` projection + `computeWorkerPlacement`), and the anti-drift-mirrored
  `dhall/ClusterTopologySchema.dhall`.

## Cross-References

- [Reconciler-with-predicates lifecycle doctrine](./lifecycle_reconciliation_doctrine.md)
- [Pure FP Standards — illegal states unrepresentable](./pure_fp_standards.md#gadt-indexed-state-machines)
- [Host Platform Doctrine — host-resident workers](./host_platform_doctrine.md)
- [Resource Scaling Doctrine — the capacity half of rule i](./resource_scaling_doctrine.md)
- [Tiered Storage Capacity Doctrine — rule k per-worker JIT/model-cache budget](./tiered_storage_capacity_doctrine.md)
- [Retained Storage Lifecycle Doctrine — no-provisioner PVs](./storage_lifecycle_doctrine.md)
- [Config Doctrine](./config_doctrine.md) · [Cluster Federation Doctrine](./cluster_federation_doctrine.md) · [Engineering docs index](./README.md)
- [DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md) · [phase-1 (Sprint 1.53)](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md) · [phase-4 (Sprint 4.38)](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
