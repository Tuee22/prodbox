# Bootstrap Readiness Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/local_registry_pipeline.md, documents/engineering/config_doctrine.md, documents/engineering/pure_fp_standards.md, documents/engineering/helm_chart_platform_doctrine.md, README.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md
**Generated sections**: none

> **Purpose**: Define the shallow-gate invariant that makes the class of bootstrap readiness races
> unrepresentable — a consumer step may run only behind a barrier that exercises the exact
> dependency call path it will use, with bootstrap ordering derived from a config-sourced,
> pure-checked dependency/readiness graph rather than a hand-written sequence.

## 0. Canonical Doctrine Statements

1. **The shallow-gate invariant.** A bootstrap step that connects to, writes to, or otherwise
   depends on component `A` may run only behind a readiness barrier that exercises the **specific
   `A`-facing call path** the step will use. A proxy signal — a front-door HTTP probe, a
   resource-exists check, or a probe issued from a different pod at a different time — does **not**
   satisfy a deep dependency edge and is a doctrine violation when used as one.
2. **A readiness race is unrepresentable, not merely avoided.** Bootstrap ordering is a pure
   projection over a typed dependency/readiness graph, so a plan that schedules a consumer before
   its dependency's real readiness is proven is not a well-formed value — it fails graph expansion,
   not a live cluster.
3. **Readiness is externally-authoritative state.** The cluster is the source of truth for whether
   a component is ready; readiness is therefore a flat, exhaustively-matched ADT computed by a pure
   projection over observed state, **never** a GADT phantom-state command machine (see
   [pure_fp_standards.md](./pure_fp_standards.md)). The "unrepresentable" guarantee lives in the
   graph's *validity* (pure, expansion-time) and the observation *soundness* rule, not in
   type-level readiness states.
4. **Cannot-observe is never ready.** A readiness probe that cannot reach its target returns
   `Unreachable`, and `Unreachable` gates closed. This is the `ResidueStatus` soundness rule of
   [lifecycle_reconciliation_doctrine.md §3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
   applied to bring-up.

## 1. The Failure Mode

The motivating defect: `cluster reconcile` mirrors container images into the in-cluster registry
(`registry:2`, front-door namespace/Service `harbor`) by pushing to `127.0.0.1:30080`. The registry
streams each pushed blob to its S3 storage backend, `minio.prodbox.svc.cluster.local`. Every barrier
in front of the mirror step proved only that the registry front door served `GET /v2/` — which
`registry:2` answers **without touching S3** — so the first operation that ever exercised the
registry→MinIO write path was the mirror push itself, and a transient DNS/endpoint-programming gap
surfaced there as `dial tcp: lookup minio.prodbox.svc.cluster.local: no such host`. The earlier
"MinIO is serving" proof (the storage-bucket-init Job) had resolved that name from a **different,
already-terminated pod at an earlier time**, so it did not bind the registry pod's live view.

The gate was *shallow*: it proved a proxy (`/v2/`, a prior pod's DNS) rather than the exact edge the
next step used (this registry pod writing a blob to MinIO now).

## 2. The Class: GATED vs RACY

A readiness barrier is **deep** (correct) when it exercises the same interface the guarded step
will use, and **shallow** (racy) when it proves a strictly weaker resource. The supported bootstrap
graph already contains ~15 deep edges — StatefulSet/Deployment rollout waits, `helm --wait` on the
consuming pod, custom-resource `Ready` waits, Job `complete` on a Job that *is* the dependent work,
and in-consumer retry loops. The racy edges are precisely those whose barrier is shallower than the
guarded call path:

| Consumer → dependency | Gate today | Why it is shallow |
|---|---|---|
| image-mirror push → registry → MinIO S3 (home) | registry `GET /v2/` only | `/v2/` never touches the S3 driver |
| runtime-image push → registry → MinIO S3 (home) | none of its own | relies on the shallow `/v2/` gate upstream |
| EKS image-mirror Job → registry → MinIO S3 | Job `complete` (post-hoc) | proves the push finished/exhausted, not that S3 was reachable first |
| EKS crane custom-image push → registry → MinIO S3 | none | same missing edge on the AWS substrate |
| chart deploy → Patroni operator ready | operator Deployment *exists* | existence ≠ `Available`/reconciling |

The discriminator is uniform: **deep edges probe the exact call path; shallow edges probe a proxy.**
The class to eliminate is "any dependency edge guarded by a proxy signal."

## 3. Making the Class Unrepresentable

Three mechanisms compose. Each honors Statement 3 (external state is projected, not commanded).

### 3.1 M1 — Ordering is derived, not hand-written

Bootstrap reconcile order is a pure topological projection over an `EffectDAG` of component nodes,
reusing the existing pure acyclic expansion and missing-node rejection of the prerequisite DAG (see
[prerequisite_dag_system.md](./prerequisite_dag_system.md)). Because order is computed from declared
edges rather than list position, a consumer cannot be scheduled before its dependency by
reordering — there is no hand-maintained sequence to reorder, and no parallel narration to fall out
of sync. This retires the imperative `runSequentially` bring-up list and its hand-synced plan
narration (owned for removal in the cleanup ledger).

### 3.2 M2 — The dependency/readiness graph is Dhall-sourced

Every bootstrap component declares, in the Tier-0 configuration
([config_doctrine.md](./config_doctrine.md)), its `depends_on` edges and a typed `readiness` probe.
Graph validity — acyclicity, no dangling dependency id, and **every dependency edge carrying a
readiness node** — is checked by the pure `EffectDAG` expansion when the config is projected. A
configuration that expresses a consumer→dependency edge without a matching readiness barrier does
not expand to a valid bring-up graph, so a bootstrap readiness race **cannot be represented by the
Dhall** in the first place.

### 3.3 M3 — The readiness probe must match the edge kind

`ReadinessProbe` is a closed ADT whose constructors are ranked by the interface they exercise. A
dependency edge that performs a backend write (for example, registry → MinIO S3) is satisfiable only
by a probe constructor that performs a **real round-trip through the consumer's own interface** — a
canary blob push through the registry, or the registry storagedriver health surface wired into
readiness. Proxy constructors (front-door HTTP, resource-exists) are distinct, weaker values that
cannot satisfy a backend-write edge; using one where a deep probe is required is a type mismatch,
not a runtime surprise. Observation obeys Statement 4: a probe that cannot reach its target yields
`Unreachable` and gates closed. This is the deep-gate discipline that
[prerequisite_doctrine.md §4](./prerequisite_doctrine.md#4-patterns) already gestures at when it
exiles steady-state waits to explicit lifecycle steps — this doctrine makes "which steady-state,
proving which edge" a typed obligation rather than an author's discretion, and
[local_registry_pipeline.md §2.1](./local_registry_pipeline.md#21-registry-readiness-contract) is
its first worked example (the `/v2/` front-door signal is explicitly *not* the registry→MinIO edge
proof).

## 4. Retry Posture Is Not a Substitute for a Deep Gate

A retry loop that misclassifies the dependency's characteristic failure is a shallow gate wearing a
retry's clothes. The mirror push retry classified transient name-resolution failures
(`no such host` / `dial tcp` / `lookup`) as non-retryable, so it failed the whole bootstrap on first
contact. Retry classifiers on a dependency edge must treat that edge's transient reachability
failures as retryable; but retry is a robustness backstop, not the barrier — the deep readiness gate
(M3) is what removes the race, and the corrected classifier only bounds residual jitter.

## 5. Intent Ownership

**Owned statement**: This document is the SSoT for the shallow-gate invariant, the GATED-vs-RACY
discriminator, and the M1/M2/M3 mechanisms that make bootstrap readiness races unrepresentable. The
DAG mechanics, the fail-fast-vs-steady-state seam, the reconcile/soundness model, the config surface,
the pure-FP external-state rule, the registry worked example, and chart dependency ordering each
remain owned by their own SSoT and are linked, not restated.

**Linked dependents**:
- Source: `src/Prodbox/Config/ComponentGraph.hs` (the typed graph, the `ReadinessProbe` deep/proxy
  ranking, and `validateComponentGraph` — the M2/M3 foundation, Sprint `1.56`),
  `src/Prodbox/EffectDAG.hs` (the shared `acyclicTopologicalOrder` expansion reused by the graph —
  M1), `src/Prodbox/Prerequisite.hs`, `src/Prodbox/CLI/Rke2.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`,
  `src/Prodbox/Lib/EksImageMirror.hs`, `src/Prodbox/Config/Tier0.hs` (the `components` Tier-0 field).
- Docs: [prerequisite_doctrine.md](./prerequisite_doctrine.md),
  [prerequisite_dag_system.md](./prerequisite_dag_system.md),
  [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md),
  [local_registry_pipeline.md](./local_registry_pipeline.md),
  [config_doctrine.md](./config_doctrine.md), [pure_fp_standards.md](./pure_fp_standards.md),
  [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md).
- Plan: adoption is scheduled through Sprints `1.56` (config/DAG foundation), `3.23` (chart edges),
  `4.43` (core reconcile ordering + registry→MinIO gate), and `7.31` (AWS-substrate parity), tracked
  in [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 6. Cross-References

- [prerequisite_doctrine.md](./prerequisite_doctrine.md) — fail-fast prerequisite gate vs
  steady-state runtime wait (§0/§4).
- [prerequisite_dag_system.md](./prerequisite_dag_system.md) — pure DAG construction, acyclicity, and
  missing-node rejection reused by M1/M2.
- [lifecycle_reconciliation_doctrine.md §3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
  — `ResidueStatus` three-valued observation and the `Unreachable → refuse` soundness rule.
- [local_registry_pipeline.md §2.1](./local_registry_pipeline.md#21-registry-readiness-contract) —
  the registry readiness contract and the `/v2/`-is-not-the-S3-edge worked example.
- [config_doctrine.md](./config_doctrine.md) — Tier-0 config surface hosting the component
  dependency/readiness graph.
- [pure_fp_standards.md](./pure_fp_standards.md) — external-state-is-projected (not a GADT) rule.
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) — chart dependency edges and
  the chart→operator `Available` gate.
