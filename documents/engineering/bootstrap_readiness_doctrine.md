# Bootstrap Readiness Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/local_registry_pipeline.md, documents/engineering/config_doctrine.md, documents/engineering/pure_fp_standards.md, documents/engineering/helm_chart_platform_doctrine.md, README.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md
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
   not a live cluster. *(Adoption status in §3.1: the graph/tie-break foundation landed in Sprints
   `1.56`/`1.58`, and Sprint `4.45` now derives the local reconcile order and rejects an invalid
   expansion on the execution path. Status authority:
   [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).)*
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
and in-consumer retry loops. The motivating pre-remediation edges were those whose barrier was
shallower than the guarded call path:

| Consumer → dependency | Former shallow gate | Why it was shallow |
|---|---|---|
| image-mirror push → registry → MinIO S3 (home) | registry `GET /v2/` only | `/v2/` never touches the S3 driver |
| runtime-image push → registry → MinIO S3 (home) | none of its own | relies on the shallow `/v2/` gate upstream |
| EKS image-mirror Job → registry → MinIO S3 | Job `complete` (post-hoc) | proves the push finished/exhausted, not that S3 was reachable first |
| EKS crane custom-image push → registry → MinIO S3 | none | same missing edge on the AWS substrate |
| chart deploy → Patroni operator ready | operator Deployment *exists* | existence ≠ `Available`/reconciling |

Sprints `3.23`, `4.43`, and `7.31` replace these proxy-only barriers on the supported paths. The
discriminator remains uniform: **deep edges probe the exact call path; shallow edges probe a
proxy.** The forbidden class is "any dependency edge guarded by a proxy signal."

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

**Adoption (2026-07-10).** Sprint `4.43` single-sources STEP narration and execution onto the typed
step projection. Sprint `4.45` completes M1: `nativeInstallStepOrder` is exactly
`concatMap stepsForComponent (componentReconcileOrder dag)`. The plan compiler appends the
separately-owned edge tail when edge reconcile is requested. `[minBound..maxBound]` remains only an
inventory-coverage enumeration and has no ordering authority. `buildNativeInstallExecutionPlan`
validates the component DAG once and stores that DAG and exact run order in `NativeInstallPayload`;
narration and apply therefore consume the same compiled plan value. Invalid graph order, phase
regression, edge placement, step inventory/anchoring, or readiness-target coverage returns a
fail-closed `StructuredError` before mutation.

Every ordering-critical native action is anchored. The former aggregate
`ensureClusterPlatformRuntime` list is represented by first-class MetalLB, Envoy Gateway, and
Percona step IDs, and bootstrap/steady executors match every step constructor explicitly. The
redundant home MinIO steady-state token is gone because it performed no distinct mutation. These
are intentional plan-surface changes: both reconcile goldens replace the aggregate platform token
with three component steps and remove the redundant MinIO token. The generic sequential fold
remains a total execution primitive; it is not an ordering authority.

### 3.2 M2 — The dependency/readiness graph is Dhall-sourced

Every bootstrap component declares, in the Tier-0 configuration
([config_doctrine.md](./config_doctrine.md)), its `depends_on` edges and a typed `readiness` probe.
Graph validity — acyclicity, no dangling dependency id, and **every dependency edge carrying a
readiness node** — is checked by the pure `EffectDAG` expansion when the config is projected. A
configuration that expresses a consumer→dependency edge without a matching readiness barrier does
not expand to a valid bring-up graph, so a bootstrap readiness race **cannot be represented by the
Dhall** in the first place.

Sprint `1.58` (✅ Done 2026-07-10) makes the two bounded lifecycle cuts explicit without turning the
graph into an open-ended state machine. Sprint `1.59`'s closure audit also assigns
`ProbeServiceActive` to `ComponentClusterBase`. `ComponentVaultWorkload` (`ProbeRolloutComplete`) precedes
`ComponentGatewayDaemonPreVault` (`ProbeRolloutComplete`), which depends on MinIO, cert-manager,
the Vault workload, and the registry. Cert-manager also declares the registry edge. Because
supported root bootstrap/unseal is daemon-mediated, both the Vault
workload and pre-Vault daemon precede `ComponentVaultUnsealed` (`ProbeVaultUnsealed`).
`ComponentGatewayDaemonFull` (`ProbeBackendRoundTrip ComponentMinio`) depends on the unsealed-Vault
and pre-Vault-daemon nodes and carries a `BackendWriteEdge` to MinIO, so the declared edge kind
matches the exact backend-round-trip probe. MetalLB, Envoy Gateway, and Percona declare both their
registry and unsealed-Vault prerequisites, preventing their image/settings consumers from crossing
either dependency. Every node carries exactly one probe. The Tier-0 schema generated from these
IDs/probes remains git-ignored; Sprint `4.45` regenerated it and passed `prodbox config validate`
while binding this graph to the local reconcile order.

### 3.3 M3 — The readiness probe must match the edge kind

`ReadinessProbe` is a closed ADT whose constructors are ranked by the interface they exercise;
Sprint `1.58` adds the deep `ProbeVaultUnsealed` constructor used only by
`ComponentVaultUnsealed`. A
dependency edge that performs a backend write (for example, registry → MinIO S3) is satisfiable only
by a probe constructor that performs a **real round-trip through the consumer's own interface** — a
canary blob push through the registry, or the registry storagedriver health surface wired into
readiness. Proxy constructors (front-door HTTP, resource-exists) are distinct, weaker values that
cannot satisfy a backend-write edge; using one where a deep probe is required is a type mismatch,
not a runtime surprise. Observation obeys Statement 4: a probe that cannot reach its target yields
`Unreachable` and gates closed.

**Adoption (2026-07-10).** Sprint `1.59` completes the Phase-1 M3 seam without duplicating a
production primitive. `ReadinessObservation = ReadyObserved | NotReadyYet Text | Unreachable Text`
is the bring-up inverse-polarity twin of
[lifecycle_reconciliation_doctrine.md §3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
`ResidueStatus`; reachable actions report
`ReadinessProbeResult = ReadinessProbeReady | ReadinessProbePending Text`. Each typed
`ComponentReadinessTarget` constructor carries its component/backend identity plus one injected
one-shot action, and `observeComponentReadiness` dispatches exhaustively over the closed
`ReadinessProbe` ADT. The target action closes over caller-owned coordinates; this module owns no
parallel endpoint, namespace, resource, repository-root, or credential literals.

Only `ReadyObserved` opens the gate. A target/probe mismatch refuses immediately in
`waitForComponentReadiness`, before the incompatible action or poll loop runs. A compatible action's
pending result becomes `NotReadyYet`; an observation failure becomes `Unreachable`. Both lower to
bounded `PollPending` readings and fail closed on exhaustion. Generic `PollFailed` remains
`pollUntilReady`'s immediate hard-error arm; `Unreachable` is deliberately distinct and bounded.

Sprint `3.24` installs the first production consumer of this seam. ChartPlatform's
`operatorAvailableTarget` registry matches every current `ComponentId`: Percona maps to an
`OperatorAvailableTarget`, and every other current ID maps explicitly to a fail-closed unsupported
result. The Percona action is a one-shot CRD-then-Deployment observer using `--ignore-not-found` for
both queries and accepting only `Available=True`. Graph-projected operator gates route through
`observeComponentReadiness`; `NotReadyYet` and `Unreachable` both close chart mutation. Exhaustive
matching plus the warning-clean build forces a decision when a new constructor is added. Because
configuration is data, however, selecting an already-existing unsupported ID remains a runtime
fail-closed mismatch; the doctrine does not overstate that case as universally compile-time.

Sprint `4.45` installs the local reconcile binding. Its total native target factory assigns a
one-shot action to every non-chart component: systemd service state for cluster base; Kubernetes
rollout/CRD observations for workloads and platform operators; daemon-mediated Vault seal status;
and registry/gateway backend round-trips for the declared deep edges. In particular, the supported
Vault action remains daemon-mediated gateway status reaching Vault `/v1/sys/seal-status`, not a new
host `/sys/health` probe. After the final step in a component group, a bounded readiness gate polls
that target's injected one-shot action; the registry's existing deep S3 barrier additionally remains
immediately before the first image write. `NotReadyYet` and `Unreachable` keep the gate closed.

Sprint `5.15` installs the TestRunner restore binding. `Prodbox.TestRestore` owns one typed,
substrate-aware `RestoreCyclePlan`; the bootstrap and postflight paths project its exact step list
through one total interpreter and differ only when `RestoreWithKeycloakSmtp` inserts the optional
SMTP step after gateway reconciliation and before the dependent charts. The home TestRunner
projection remains explicitly `SubstrateHomeLocal`; Sprint `7.32` adds the explicit `SubstrateAws`
projection rather than an implicit fallback.

Before the optional SMTP step calls `syncKeycloakSmtpForSupportedRuntime`, TestRunner obtains the
canonical loopback endpoint through `gatewayEndpointFromEnv` and composes
`gatewayDaemonLivenessPrecondition` with the exported
`observeGatewayBackendRoundTripOnce`. That adapter performs exactly one gateway object-store GET on
each invocation: a credentialed present-or-absent response is ready, a degraded HTTP 503 is pending,
and transport failure is unreachable. `waitForComponentReadiness` owns the only bounded retry loop
over the `ComponentGatewayDaemonFull`/`ProbeBackendRoundTrip ComponentMinio` target. Exhaustion
becomes a `Preconditions.StructuredError` naming the loopback endpoint and declaring that no SMTP
sync started; the adapter does not nest RKE2's older `pollGatewayObjectStore` loop.

Code-owned validation passes 1280/1280 unit tests for exact restore projection, SMTP anchoring, and
ready/pending/unreachable precondition decisions. The targeted `resource-guardrails` built-frontend
fixture also passes against fake gateway readiness as a general CLI regression check. Its named
plan runs neither supported-runtime restore projection and does not select the SMTP step, so it is
not evidence for the shared interpreter or the new gate end to end. A live home
`prodbox test all` restore is retained as a non-blocking Standard-O proof.

Sprint `7.32` installs the AWS production binding. `AwsSubstratePlatform` and the home RKE2 driver
both compile substrate-owned closed step ADTs through `Prodbox.Lifecycle.AnchoredReconcile`; the
validated configured DAG determines component order, while each substrate owns only stable
within-component mutations and final readiness barriers. The AWS compiler refuses missing,
duplicate, misanchored, phase-regressing, graph-inverted, readiness-less, or AWS-inapplicable
dependency projections before stack-output reads or platform mutation. MetalLB is explicitly empty
on AWS; AWS Load Balancer Controller belongs to cluster base. The edge-only ACME/admin-route tail is
separate from graph components.

AWS one-shot targets observe EKS nodes plus AWS Load Balancer Controller, MinIO and Vault rollouts,
the containerd-mirror DaemonSet plus the registry→MinIO round trip, cert-manager/Envoy rollouts and
CRDs, Percona `Available`, daemon-mediated Vault seal state, and gateway pre-/post-Vault state. A
loopback gateway Service port-forward is bracketed, positively established through the daemon state
endpoint, and supervised on one local port across Vault bootstrap and full-mode convergence; when
the selected Pod rolls, the supervisor re-establishes `kubectl` and the bounded daemon retry bridges
the reconnect gap. No home NodePort fallback or fixed readiness sleep is used. TestRunner projects
Gateway → SMTP → VS Code → API → WebSocket from the same
restore builder after the three AWS stack reconciles. Code-owned proof is unit 1286/1286 plus
`prodbox dev check` exit 0; live AWS aggregate proof remains non-blocking Standard O.

This is the deep-gate discipline that
[prerequisite_doctrine.md §4](./prerequisite_doctrine.md#4-patterns) already gestures at when it
exiles steady-state waits to explicit lifecycle steps — this doctrine makes "which steady-state,
proving which edge" a typed obligation rather than an author's discretion, and
[local_registry_pipeline.md §2.1](./local_registry_pipeline.md#21-registry-readiness-contract) is
its first worked example (the `/v2/` front-door signal is explicitly *not* the registry→MinIO edge
proof).

## 4. Retry Posture Is Not a Substitute for a Deep Gate

A retry loop that misclassifies the dependency's characteristic failure is a shallow gate wearing a
retry's clothes. The Helm retry classifier omitted transient name-resolution failures
(`no such host` / `dial tcp` / `lookup` / `name resolution`) and `connection refused` even though the
registry-publication classifier retried them, so a Helm install could fail the whole bootstrap on
first contact. Retry classifiers on a dependency edge must treat that edge's transient reachability
failures as retryable; but retry is a robustness backstop, not the barrier — the deep readiness gate
(M3) is what removes the race, and the corrected classifier only bounds residual jitter.

Sprint `1.57` establishes the shared classifier SSoT in `src/Prodbox/Service.hs`.
`TransientFailureClass` owns the common name-resolution, connection, transient-HTTP, and timeout
fragment groups, while `isRetryableTransientFailure :: [String] -> String -> Bool` adds only a
caller's operation-specific fragments and normalizes casing at the shared boundary. The Phase-1
`isRetryableAwsValidationFailure` caller delegates to it. Sprint `4.46` moved all three RKE2-owned
callers — Route 53 credential propagation, Helm, and registry publication — onto the same base;
Sprint `7.32` moves the EKS image-mirror caller onto that base as well.

`checkInlineRetrySubstringLists` enforces that a new top-level `isRetryable*` substring classifier
delegates to this base. Its transitional exception is deliberately narrow: exact path-and-function
pairs grandfathered the Route 53, Helm, Harbor, and EKS classifiers, rather than exempting whole
modules. Sprint `4.46` removed all three RKE2 entries when those callers delegated, and Sprint
`7.32` removed the final EKS entry. No legacy retry-classifier allowance remains.

## 5. Intent Ownership

**Owned statement**: This document is the SSoT for the shallow-gate invariant, the GATED-vs-RACY
discriminator, and the M1/M2/M3 mechanisms that make bootstrap readiness races unrepresentable. The
DAG mechanics, the fail-fast-vs-steady-state seam, the reconcile/soundness model, the config surface,
the pure-FP external-state rule, the registry worked example, and chart dependency ordering each
remain owned by their own SSoT and are linked, not restated.

**Linked dependents**:
- Source: `src/Prodbox/Config/ComponentGraph.hs` (the typed graph, the `ReadinessProbe` deep/proxy
  ranking, and `validateComponentGraph` — the M2/M3 foundation, Sprint `1.56`; Sprint `1.58`'s
  completed split is `ComponentVaultWorkload`/`ComponentVaultUnsealed` with
  `ProbeRolloutComplete`/`ProbeVaultUnsealed`, plus `ComponentGatewayDaemonPreVault`/
  `ComponentGatewayDaemonFull` with `ProbeRolloutComplete`/
  `ProbeBackendRoundTrip ComponentMinio`, one probe per node), `src/Prodbox/EffectDAG.hs` (the shared
  `acyclicTopologicalOrder` expansion reused by the graph — M1; Sprint `1.58` adds the caller tie-break
  and `ComponentGraph` supplies `fromEnum`),
  `src/Prodbox/Lifecycle/ReadinessObservation.hs` (Sprint `1.59`'s M3 seam —
  `ReadinessObservation`, `ReadinessProbeResult`, typed `ComponentReadinessTarget`, exhaustive
  `observeComponentReadiness`, and bounded `waitForComponentReadiness`),
  `src/Prodbox/Prerequisite.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/TestRestore.hs`,
  `src/Prodbox/TestRunner.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`,
  `src/Prodbox/Lib/EksImageMirror.hs`, `src/Prodbox/Config/Tier0.hs` (the `components` Tier-0 field).
- Docs: [prerequisite_doctrine.md](./prerequisite_doctrine.md),
  [prerequisite_dag_system.md](./prerequisite_dag_system.md),
  [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md),
  [local_registry_pipeline.md](./local_registry_pipeline.md),
  [config_doctrine.md](./config_doctrine.md), [pure_fp_standards.md](./pure_fp_standards.md),
  [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md).
- Plan: Sprints `1.56` (config/DAG foundation), `3.23` (chart edges), `4.43` (narration
  single-sourcing + deep registry→MinIO gate), and `7.31` (AWS deep-gate parity) landed the
  **foundation**. Sprints `1.57`–`1.59` have since landed the retry-classifier SSoT, bounded
  two-phase node split + caller-ranked `EffectDAG`, and injected-action readiness seam; Phase `1`
  is reclosed. Sprint `2.30` closed the gateway-daemon Vault-role SSoT and Sprint `3.24` closed the
  ChartPlatform operator-gate binding, reclosing Phases `2` and `3`. Sprints `4.44` and `4.45` have
  since closed the typed registry backend and local graph-derived order/readiness binding. Sprint
  `4.46` then closed all three RKE2 retry-classifier migrations and reclosed Phase `4`. Sprint
  `5.15` closed the shared restore plan plus daemon-readiness precondition and reclosed Phase `5`.
  Sprint `7.32` then closed the AWS graph/readiness, classifier, scoped-port-forward, and restore
  projections and reclosed Phase `7`; all completion sprints in this refactor are Done.

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
