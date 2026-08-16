# Prerequisite DAG System

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Define the DAG construction and reduction model for prerequisite execution.

## 1. Core Model

The prerequisite DAG system is defined by:

- `EffectNode` values (`effectNodeId`, `effectNodeDescription`, `effectNodeRemedyHint`,
  `effectNodePrerequisites`, `effectNodeEffect`) keyed by stable IDs
- explicit dependency edges carried in `effectNodePrerequisites`
- a canonical registry `prerequisiteRegistry :: Map PrerequisiteId EffectNode` in
  `src/Prodbox/Prerequisite.hs`
- graph construction in `src/Prodbox/EffectDAG.hs` (`fromRootIds`, `transitiveClosureIds`)
- graph execution in `src/Prodbox/EffectInterpreter.hs` (`runEffectDAG`)

Per the [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md), this same pure
construction (acyclicity + missing-node rejection) also carries component **bring-up/readiness**
edges lowered from the Tier-0 config, so that reconcile ordering is a projection over the graph and a
consumer-before-dependency readiness race is rejected by the canonical lowering before execution.

Node IDs use the closed `PrerequisiteId` ADT, so root selection and dependency edges are checked by
the compiler rather than by raw-string equality. `prerequisiteIdText` is an output projection, not
an alternate construction path.

The supported command surface does not construct ad-hoc prerequisite orderings outside this model.

### 1A. Kubernetes substrate boundary

The generic Kubernetes branch is intentionally independent of the home-local cluster
implementation:

```text
ToolKubectl -> K8sClusterReachable -> K8sReady
```

`K8sClusterReachable` executes the authoritative `kubectl cluster-info` observation against the
kubeconfig selected for the active substrate. The selected kubeconfig may name the home RKE2 API,
an EKS API, or another supported substrate; the graph does not infer substrate identity from host
files or services.

`KubeconfigExists`, `KubeconfigHomeExists`, `Rke2ConfigExists`, `Rke2Installed`,
`Rke2ServiceExists`, and `Rke2ServiceActive` remain explicit nodes for home-local plans. None may
occur in the transitive closure of `K8sClusterReachable` or `K8sReady` unless a caller separately
selects a home-local root. Unit tables pin both the direct edges and this negative-space closure, so
an AWS-selected run cannot acquire an accidental dependency on `/etc/rancher/rke2` or
`rke2-server.service`.

## 2. Prerequisite Result Propagation

Prerequisite failures propagate from the root cause upward.

- a failing prerequisite should emit one actionable error
- dependents should preserve that failure rather than replace it with generic noise
- command runners should stop before deeper runtime work begins

## 3. Reduction and Determinism

For a fixed root set and registry, prerequisite expansion must be deterministic.

- missing prerequisite IDs fail at expansion time rather than being discovered later at execution
- no missing prerequisite IDs (`transitiveClosureIds` returns `Left` naming the absent ID)
- no cycles
- no duplicate execution of the same satisfied node within one run
- stable transitive closure for the selected roots (`transitiveClosureIds` sorts its result)

Acyclicity is enforced by the canonical smart-construction path, not merely test-guarded:
`transitiveClosureIds` / `fromRootIds` return `Left` on a back-edge — a node that (transitively)
depends on itself. Cycle detection sits in the same `Either String` expansion path that already
rejects missing IDs, and the interpreter memoizes satisfied nodes so no node executes twice within
one run. This is not presently a type invariant: `EffectDAG (..)` and `EffectNode (..)` are exported,
so an arbitrary record can bypass `fromRootIds` and reach the interpreter. Supported prerequisite
commands use the rejecting constructor; closing the exported-constructor escape would be a separate
API-hardening change.

`test/unit/Main.hs` retains coverage of the canonical-construction contract as defense-in-depth: a
back-edge supplied to `transitiveClosureIds`/`fromRootIds` is rejected before the supported command
path invokes the interpreter. The tests do not turn the exported record constructor into an opaque
proof.

The generic `EffectDAG.acyclicTopologicalOrder` carries the same back-edge and missing-node
rejection. The Tier-0 component dependency/readiness graph
(`Prodbox.Config.ComponentGraph`, owned by
[bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md)) reuses to lower its declared
`depends_on` edges into a deterministic dependencies-before-dependents bring-up order. Unlike
`transitiveClosureIds` (a text-sorted closure set for the interpreter's ready-set rendering), the
generic expansion returns a topological order. The current generic expansion separates the key
renderer used for diagnostics from a caller-supplied deterministic tie-break: roots and adjacency
are visited by `(tieBreak key, render key)`, so independent nodes do not accidentally inherit
human-readable text order. `Prodbox.Config.ComponentGraph` supplies `fromEnum ComponentId`, making
constructor declaration order the explicit tie-break for both component reconcile and chart
projections over the split nodes; the generic API remains usable by callers with a different
ordering doctrine. Unit coverage proves the caller rank wins even when rendered text orders the
same independent nodes oppositely. The result is still a pure function of the graph plus the
caller's explicit ordering projection. Reconcile-driver adoption and remaining work are tracked only
in the [Development Plan](../../DEVELOPMENT_PLAN/README.md).

The caller-injected `ComponentReadinessTarget` is a historical observation seam, not
the target graph contract. The replacement graph stores pure operation-indexed
`CapabilityRequirement` values. Runtime reconnaissance resolves a unique opaque
`CapabilityRef kind`, and observation, admission, and execution consume that same reference and
absolute deadline. Pending and unobservable remain flat gate-closed observations; a separately
injected action or endpoint cannot satisfy an edge. The concrete algebra and migration boundary
are owned by the
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md); implementation
status remains in the [Development Plan](../../DEVELOPMENT_PLAN/README.md).

## 4. Test Command Integration

`src/Prodbox/TestRunner.hs` uses the prerequisite DAG system for Phase `1/2` of the public
`prodbox test` workflow.

- selected named suites determine the root prerequisites
- cluster-backed suites may add a runbook step after the DAG gate
- named validation payloads execute only after the DAG succeeds

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
