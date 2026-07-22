# Prerequisite DAG System

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effect_interpreter.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/unit_testing_policy.md, documents/engineering/bootstrap_readiness_doctrine.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md
**Generated sections**: none

> **Purpose**: Define the DAG construction and reduction model for prerequisite execution.

## 1. Core Model

The prerequisite DAG system is defined by:

- `EffectNode` values (`effectNodeId`, `effectNodeDescription`, `effectNodeRemedyHint`,
  `effectNodePrerequisites`, `effectNodeEffect`) keyed by stable IDs
- explicit dependency edges carried in `effectNodePrerequisites`
- a canonical registry `prerequisiteRegistry :: Map String EffectNode` in
  `src/Prodbox/Prerequisite.hs`
- graph construction in `src/Prodbox/EffectDAG.hs` (`fromRootIds`, `transitiveClosureIds`)
- graph execution in `src/Prodbox/EffectInterpreter.hs` (`runEffectDAG`)

Per the [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md), this same pure
construction (acyclicity + missing-node rejection) also carries component **bring-up/readiness**
edges lowered from the Tier-0 config, so that reconcile ordering is a projection over the graph and a
consumer-before-dependency readiness race is not a well-formed value.

Node IDs are presently raw `String`s. The intended target is a typed `PrerequisiteId` ADT so
that root selection and dependency edges are checked by the compiler rather than by string
equality (Sprint 5.6).

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

Acyclicity is enforced at construction, not merely test-guarded: `transitiveClosureIds` /
`fromRootIds` return `Left` on a back-edge — a node that (transitively) depends on itself — so a
cyclic registry can never produce an `EffectDAG`. Cycle detection sits in the same `Either String`
expansion path that already rejects missing IDs, and the interpreter memoizes satisfied nodes so no
node executes twice within one run (Sprint 1.31).

`test/unit/Main.hs` retains coverage of these invariants as defense-in-depth, but the construction
path — not the test suite — is the authoritative gate: a back-edge is rejected by
`transitiveClosureIds`/`fromRootIds` before any `EffectDAG` reaches the interpreter.

Sprint `1.56` extracts the same back-edge cycle rejection + missing-node rejection into the generic
`EffectDAG.acyclicTopologicalOrder`, which the Tier-0 component dependency/readiness graph
(`Prodbox.Config.ComponentGraph`, owned by
[bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md)) reuses to lower its declared
`depends_on` edges into a deterministic dependencies-before-dependents bring-up order. Unlike
`transitiveClosureIds` (a text-sorted closure set for the interpreter's ready-set rendering), the
generic expansion returns a topological order. Sprint `1.58` (✅ Done 2026-07-10) separates the key
renderer used for diagnostics from a caller-supplied deterministic tie-break: roots and adjacency
are visited by `(tieBreak key, render key)`, so independent nodes do not accidentally inherit
human-readable text order. `Prodbox.Config.ComponentGraph` supplies `fromEnum ComponentId`, making
constructor declaration order the explicit tie-break for both component reconcile and chart
projections over the split nodes; the generic API remains usable by callers with a different
ordering doctrine. Unit coverage proves the caller rank wins even when rendered text orders the
same independent nodes oppositely. The result is still a pure function of the graph plus the
caller's explicit ordering projection. Phase `4` Sprint `4.45` remains the owner of reconcile-driver
consumption; Sprint `1.58` changes only the pure DAG/config foundation.

Sprint `1.59`'s caller-injected `ComponentReadinessTarget` is a historical observation seam, not
the target graph contract. The replacement graph stores pure operation-indexed
`CapabilityRequirement` values. Runtime reconnaissance resolves a unique opaque
`CapabilityRef kind`, and observation, admission, and execution consume that same reference and
absolute deadline. Pending and unobservable remain flat gate-closed observations; a separately
injected action or endpoint cannot satisfy an edge. The concrete algebra and migration boundary
are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) and Sprint
`1.61`.

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
