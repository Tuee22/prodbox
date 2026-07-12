# Unit Testing Policy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md,
DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md,
DEVELOPMENT_PLAN/phase-0-planning-documentation.md,
DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md,
DEVELOPMENT_PLAN/phase-2-gateway-dns.md,
DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md,
DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md,
DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md,
DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md,
DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md,
DEVELOPMENT_PLAN/phase-8-email-invite-auth.md,
documents/engineering/README.md,
documents/engineering/aws_integration_environment_doctrine.md,
documents/engineering/aws_test_environment.md,
documents/engineering/cli_command_surface.md,
documents/engineering/code_quality.md,
documents/engineering/dependency_management.md,
documents/engineering/distributed_gateway_architecture.md,
documents/engineering/effectful_dag_architecture.md,
documents/engineering/effect_interpreter.md,
documents/engineering/envoy_gateway_edge_doctrine.md,
documents/engineering/helm_chart_platform_doctrine.md,
documents/engineering/integration_fixture_doctrine.md,
documents/engineering/lifecycle_control_plane_architecture.md,
documents/engineering/lifecycle_reconciliation_doctrine.md,
documents/engineering/prerequisite_dag_system.md,
documents/engineering/prerequisite_doctrine.md,
documents/engineering/pure_fp_standards.md,
documents/engineering/refactoring_patterns.md,
documents/engineering/bootstrap_readiness_doctrine.md,
documents/engineering/resource_scaling_doctrine.md,
documents/engineering/streaming_doctrine.md,
documents/engineering/test_topology_doctrine.md
**Generated sections**: none

> **Purpose**: Define interpreter-only mocking, pure/model/property testing, production-adapter
> composition, load and chaos qualification, and the public `prodbox test` contract.

Test topology and `.test-data/` isolation are owned by
[Test Topology Doctrine](./test_topology_doctrine.md). Physical control-plane topology and its
capability invariants are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). Suite status and
current-revision deployment evidence are owned only by the
[Development Plan](../../DEVELOPMENT_PLAN/README.md).

## 0. Canonical Statements

1. Skip/xfail is prohibited by default. Missing prerequisites fail fast with an actionable typed
   error.
2. Pure code never touches a mock. Fakes and injected failures exist only at subprocess, client, or
   interpreter boundaries.
3. A fake proves the pure decision and boundary mapping it exercises; it does not qualify the real
   adapter, service identity, resource envelope, or deployment topology.
4. Operation-indexed capability tests must use the same opaque reference for observation,
   admission, and execution. Tests that inject an arbitrary `IO` action behind a capability label
   are forbidden.
5. Every durable external transition is tested as `observe -> decide -> commit/effect ->
   re-observe`, including conflict, cancellation, restart, and applied-but-response-lost paths.
6. One monotonic absolute deadline covers queue wait, auth refresh, external I/O, read-back,
   persistence, response, retry delay, and cancellation.
7. Memory-only stability is insufficient. Deployment qualification includes CPU throttling,
   service rate, queue occupancy/wait, saturation, deadline misses, and latency.
8. Cleanup obligations are registered before mutation and interpreted as an always-run DAG.
   Failure injection must prove that independent cleanup continues and all outcomes aggregate.
9. A revision that changes deployment behavior is not closed by unit/fake evidence alone. It must
   satisfy [Development Plan Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

## 1. The Interpreter-Only Mocking Doctrine

### 1.1 Core rule

Pure helpers, graph construction, codecs, renderers, decision tables, `decide`/`evolve`, resource
algebra, and cleanup scheduling are tested using concrete values. They do not import mock APIs or
effect classes solely for test control.

Boundary substitutions are appropriate for:

- subprocess execution;
- HTTP, Vault, S3/MinIO, Kubernetes, DNS, and AWS clients;
- monotonic clock and random/nonce generation;
- durable CAS and journal storage;
- bounded queue and provider-worker interpretation; and
- retained-home material custody Transit seal/rewrap plus selected-target materialization; and
- process lifecycle and fault injection.

A boundary fake returns the same typed observation/result as production. Tests must not add a
test-only Boolean success path that production cannot produce.

### 1.2 Test hooks

Long-running daemons may expose boundary-owned no-op production hooks for deterministic lifecycle
coordination. Hooks may observe scheduling points or block an interpreter at a named boundary; they
must not change domain decisions. Direct `threadDelay` for race coordination is forbidden.

## 2. Unit vs Integration Tests

### Test Categories

| Category | What it proves | Canonical location |
|----------|----------------|--------------------|
| Pure unit tables | Parsing, validation, ADTs, graph rejection, `decide`/`evolve`, admission, deadline, cleanup scheduling | `test/unit/` |
| Conformance tier | Cross-artifact agreement between compiled registries and their projections | `prodbox-unit` plus the canonical quality gate |
| Parser tests | `argv -> Command` via `execParserPure`, including rejection | `test/unit/Parser.hs` |
| Property tests | Codec/replay/idempotency/monotonicity/bounds/deadline laws | `prodbox-unit` |
| Deterministic concurrency simulation | Actor interleavings, saturation, cancellation, restart, response loss | dedicated pure/simulation test module |
| Built-frontend integration | Real binary routing and fake boundary behavior | `test/integration/` |
| Daemon lifecycle | Real process/config/health/admission/drain/restart contract | `test/daemon-lifecycle/` |
| Production-adapter composition | Real binary with native MinIO/Vault/CAS clients and exact identity binding | named integration validation |
| Load qualification | Authored steady rate plus burst under exact cgroups | named integration validation |
| Chaos qualification | Kill/isolate/restart at every durable transition boundary | named integration validation |
| Pulumi infrastructure | Provision, assert, always-run cleanup, residue re-observation | `test/pulumi/` and named validations |
| Golden tests | CLI, plans, health/ready/metrics, generated docs | `test/golden/` |

The canonical named-validation inventory is defined in `src/Prodbox/TestValidation.hs`; phase and
substrate coverage are defined by `TestPlan` and
[DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md), not duplicated here.

## The Conformance Tier

The conformance tier is the pre-cluster, seconds-fast suite family that proves cross-artifact
agreement. A contract that crosses a compilation or serialization boundary — an HTTP route path, a
chart probe or values projection, a restore-graph edge, a residue policy, a resource envelope — is
single-sourced in a compiled value; the conformance tier proves every projection of that value
still agrees with its source. Cross-artifact drift fails the canonical quality gate
(`prodbox dev check`) in seconds; it is not deferred to the multi-hour aggregate suite.

Conformance suites use only pure values and interpreter-boundary fakes. They prove, at minimum:

- route-registry non-overlap and route round-trip;
- deployed chart values versus compiled statics equality;
- restore-graph coverage, independence, and orphan scans;
- durable CAS taxonomy against in-memory fakes;
- operation-record crash/replay resolution;
- residue-policy decision tables; and
- measured-profile certification against fixture profiles.

The planned suites are `GatewayBoundarySpec`, `RestoreGraphTotality`, `StoreLifetimePartition`,
`RetainedAuthorityStoreCas`, `OperationRecordResolution`, and `HarnessResiduePolicy`. Suite
ownership and status live in the [Development Plan](../../DEVELOPMENT_PLAN/README.md) (Sprints
`1.63`, `2.34`, `4.51`, `5.20`, and `7.34`).

## 3. Pure and Property Tests

### 3.1 Exhaustive tables

Every closed observation, command, event, decision, and failure ADT has a table covering every
constructor. Required control-plane tables include:

- capability kind/program acceptance and mismatch rejection;
- service identity, substrate, authority scope, and epoch validation;
- admission open/saturated/degraded/expired/unobservable;
- authority `decide` and `evolve` commands/events;
- closed `RetainedMaterialSchema` SMTP/EAB permit matching, flat custody observations, and every
  pending/current/per-target/superseded/tombstone transition;
- target generation duplicate/regression/digest conflict;
- retry classification and remaining-deadline refusal;
- stability warning/failure/absorbing transitions; and
- cleanup `RequiresAttempt`/`RequiresSuccess` scheduling and aggregation.

### 3.2 Properties

Use `tasty-quickcheck` for, at minimum:

- `decode . encode == id` for bounded valid values;
- deterministic render and event replay;
- duplicate command/event idempotency;
- stale authority epoch/fence/revision/generation rejection;
- monotonic operation and target generations;
- retained-material delivery never starts without the exact current source receipt, schema or
  target mismatch never materializes, and a referenced source never becomes tombstoned;
- selected-worker loss/nonce/attestation/deadline mismatch discards its target envelope and returns
  to the committed rewrap intent, while supersession deadline without complete target/consumer
  retirement evidence never authorizes source GC;
- KV-v2 soft deletion never satisfies target/custody physical version+metadata absence, and
  superseded checkpoint/custody GC never deletes while either primary/backup or a dependant refers;
- CAS conflict re-decision from the newly observed state;
- no queue, map, journal, outbox, replay window, or diagnostic projection exceeds its validated
  bound;
- one absolute deadline never increases as work descends through interpreters;
- retry plus delay never runs beyond the original deadline;
- heartbeat coalescing does not remove claim/yield/rotation intents;
- cleanup never skips an independent ready node because a sibling failed; and
- cleanup reporting retains both the primary failure and every cleanup failure.

Happy-path chronological generators alone are insufficient. Generate duplicate, reordered,
conflicting, stale, truncated, malformed, unobservable, and response-lost cases.

### 3.3 Deterministic concurrency simulation

Use `io-sim` or an equivalent deterministic scheduler for actor and authority concurrency. The
simulation controls clock, queue, cancellation, client disconnect, storage response, and worker
restart. Cover every crash point around:

```text
observe -> decide -> CAS intent -> external effect -> read-back -> CAS completion
```

For gateway emission, cover every point around:

```text
stage -> fsync -> publish -> commit -> fsync
```

The oracle proves one local transition owner, no stale-fence publication, deterministic staged
recovery, and no second actor interleaving with an incomplete transition.

## 4. Capability and Readiness Tests

### 4.1 Same-reference invariant

A production capability test resolves one opaque reference from service identity, authority scope,
substrate, and transport binding. That value supplies observation, admission, and execution. The
test must fail if any adapter attempts to substitute another endpoint or active kube context.

An observe-only operation cannot satisfy a conditional-CAS/read-back requirement. In particular:

- an absent-object GET is not a lifecycle CAS proof;
- `/healthz`, `/readyz`, rollout, or resource existence is not backend capability proof;
- a target gateway/agent observation is not retained-authority evidence; and
- a successful command exit with discarded output is not semantic readiness.

### 4.2 Four observation axes

Test process liveness, cached admission readiness, capability execution, and runtime stability
separately. `/healthz` and `/readyz` tests inject slow/unavailable backends and saturated operational
state and prove the endpoints remain constant time. Deep execution tests use a reserved coordinate
through the production client and mandatory authoritative read-back.

Mutating canaries are visible preparation actions, not hidden read-only prerequisites. A
long-running lifecycle flow submits a durable idempotent operation directly and observes its
operation ID; it does not use a point probe as a permit for a later unrelated transaction.

## 5. Production-Adapter Composition

Pure/fake proof is necessary and insufficient for a changed runtime boundary. Composition tests use:

- the built `prodbox` binary;
- the same daemon command and config shape as the chart;
- the production native S3-compatible conditional-write/read-back adapter;
- the production renewable Vault-session adapter;
- actual Service/ServiceAccount/Vault-role identity;
- the production serialization and envelope codecs;
- bounded queues and absolute deadlines; and
- the exact configured resource requests and limits.

Required scenarios include missing/corrupt/unobservable data, CAS conflict, applied-but-response-
lost, expired session refresh, auth denial, wrong service identity, wrong substrate, wrong
authority epoch, and client cancellation. The test observes the durable operation by ID after every
ambiguous response.

Retained-material composition additionally proves region-bound SMTP derivation occurs before
custody, raw IAM secret bytes never reach the home Agent, AWS-admin and external-EAB frames cannot
cross-decode, and current SMTP/EAB receipts repopulate a newly introduced target and a fresh AWS
Vault/EBS without remint or re-prompt.

A fake `aws`, `kubectl`, or HTTP trace proves only frontend mapping. It cannot be cited as evidence
that the production native client, port binding, Vault policy, or cgroup service capacity works.

## 6. Load and Runtime-Stability Qualification

### 6.1 Authored load

Each component declares steady background arrival rate, burst, queue capacity, CPU demand,
service-time budget, latency budget, and headroom in its validated service-capacity plan. The load
test applies that workload plus the documented concurrent control-plane operations.

It runs under the same CPU/memory/ephemeral-storage requests and limits as the rendered chart. A
host run without the production CPU limit is a profiling aid, not deployment qualification.

### 6.2 Required observations

The run-wide recorder captures:

- Pod UID, restart delta, current/last termination state, OOM, and memory working set;
- CPU usage plus CFS throttled periods/time;
- queue capacity, occupancy, wait, saturation refusals, and reserved-lane starvation;
- service time and end-to-end p50/p95/p99 latency;
- absolute-deadline misses and cancellation overrun;
- session refresh failures and external I/O latency; and
- missing, malformed, or unreachable samples.

Restart, OOM, failure-threshold resource breach, repeated deadline breach, starvation, and
unobservable required evidence are absorbing. Warning evidence resets only the consecutive-success
window. A replacement Pod or later idle sample cannot erase the run-wide record. Only an explicitly
compiled planned rollout may reset the success window.

The historical restart/OOM/memory-only gateway fold is an incomplete compatibility projection. It
does not qualify the redesigned services without CPU, queue, deadline, and latency evidence.

### 6.3 Isolation proof

Load Gateway Runtime while submitting and observing Lifecycle Authority work; lifecycle admission
and status must stay within budget. Load or stall the provider worker while gateway mesh, Bootstrap
Broker health, and Target Secret Agent read-back remain within their independent budgets. This
proves physical scheduling isolation rather than merely separate Haskell constructors.
Load home custody/rewrap and selected-target materialization concurrently and prove their separate
worker/session budgets cannot starve normal Target-Agent delivery or Authority recovery.

## 7. Chaos and Recovery Qualification

Fault injection terminates, pauses, partitions, or makes unobservable each of:

- Gateway Runtime and emitter journal;
- overlapping Gateway Pods around journal lock/incarnation plus every emitter stage/peer-ack
  boundary;
- Bootstrap Broker before/after init request, encrypted receipt, custody acknowledgment,
  generate-root accessor, baseline read-back, revoke, and accessor-absence read-back;
- Lifecycle Authority before/after each aggregate CAS;
- authority clock regression/unobservability, terminal-ID compaction, and pending-blob/GC scans;
- provider worker before/after the external provider accepts an action;
- every AWS `CreateAccessKey` response, target-sealing response, delete, and stable-absence read;
- retained-material custody seal, current promotion, target rewrap/materialization, supersession,
  target tombstone, and source-custody tombstone on both sides of every read-back;
- Target Secret Agent before/after seal-receipt CAS, target Vault CAS, and each read-back;
- MinIO and Vault during session refresh and durable transition; and
- the client connection before receiving each response.

Every injected point must produce one of:

- deterministic resume from committed intent;
- idempotent already-applied success after read-back;
- typed fail-closed refusal with queryable operation state; or
- explicit ambiguous/recovery state that blocks a successor until resolved.

It must never produce dual authority, stale-fence commit, generation regression, a guessed timeout
outcome, an unbounded waiter, or success without re-observation.

The stable repository-owned reproducer for the July 11 failure class is
`LCPC-2026-07-11`, exposed as
`prodbox test integration control-plane-counterexample`. It has two required profiles. The causal
profile holds the authored background load, fault schedule, and topology-normalized total control-
plane CPU/memory/ephemeral/persistence budget constant: the old allocation includes the three
250m Gateway CPU limits, while the replacement repartitions—without increasing—the same total
budget across Gateway, Authority, Broker, and Agent roles. The production profile then exercises
the independently justified rendered envelopes and capacity inequalities. A frozen, digest-bound
pre-cutover trace/simulator retained by Sprint `4.50` supplies the superseded result after its
production routes are deleted; it is test-only and cannot be selected as an interpreter. The
artifact must show the expected absent-GET-vs-CAS binding, deadline/throttling, wrong-endpoint,
applied-response-lost, and sibling-cleanup-skip signatures, then show every signature closed by the
replacement. Old/new result, normalized-envelope mapping, source, and wiring digests survive
legacy deletion; a reproducer weakened or resourced upward between runs is invalid evidence.

## Two-Phase Test Command Doctrine

### Fail-fast and preparation phases

Integration selections fail fast on missing prerequisites. The public runner uses visible phases:

1. prerequisite validation;
2. optional runbook and supported-runtime preparation;
3. test suites and named validation payloads; and
4. always-run postflight/cleanup reporting.

Prerequisites are read-only. Reconcile, canary mutation, long-lived desired presence, and runtime
restoration are visible Plan/Apply steps. A preparation failure prevents dependent payload work but
does not suppress registered independent cleanup.

### Phase Banner Rendering Contract

Phase banners are operator-facing records. They are separate stdout lines, appear in actual
execution order, and never announce payload execution before all its prerequisite/preparation
gates succeed. Postflight banners remain visible even after a body failure.

### Command-Scope Prerequisite Aggregation

The selected validation set determines its exact typed prerequisite and preparation roots. Unit-only
scope bypasses integration prerequisites. Substrate config is locked to the selected substrate;
there is no fallback. Aggregate ordering is defined by `TestPlan`.

Session-style hidden setup is forbidden. Resource allocation, durable operation submission, and
cleanup ownership are represented in the native plan and runner.

## 9. Absolute Deadline Testing

Tests construct one monotonic absolute deadline at the outer boundary and record it at every nested
interpreter. Assert that:

- remaining budget never increases;
- admission refuses when predicted queue/service time cannot fit;
- retry delay and the next attempt fit before retry begins;
- queue wait, auth refresh, I/O, read-back, response persistence, and cancellation are all charged;
- a client timeout cannot leave non-durable server work running; and
- durable work continues after disconnect only when its intent is committed and observable by
  operation ID.

Independent relative 30-second client, queue, and action timers that can compose beyond the caller
deadline are forbidden test and production shapes.

## 10. Always-Run Cleanup Validation

Cleanup tests compile a DAG whose edges distinguish `RequiresAttempt` from `RequiresSuccess`.
Before the first mutation, the scope must already hold every cleanup obligation known at that
point. Inject failure and cancellation at every body and cleanup node.

The assertions are:

- every independent ready node runs after a sibling failure;
- dependency-blocked nodes report an explicit skip reason;
- lifecycle operations are observed/resolved before dependent authority teardown;
- home control plane/application restoration is attempted independently of per-run AWS cleanup;
- credential-dependent cleanup precedes removal of each role-specific IAM/key resource;
- an identity generation remains available when required dependent cleanup failed;
- every owned lifecycle class is re-observed;
- the primary body error remains primary; and
- all cleanup failures are retained in the final report.

For destructive lifecycle commands, dry-run goldens derive their resource steps from the managed
resource registry. Integration success requires empty per-run residue and a successful fail-closed
postflight observation. `prodbox nuke` remains an explicit opt-in validation because it destroys
long-lived resources.

## 3. Forbidden Patterns

- silent skip/xfail for a required prerequisite;
- arbitrary `IO` stored in a capability/readiness target;
- probing one endpoint and executing through another;
- mocks inside pure decision code;
- `threadDelay` for concurrency coordination;
- timeout tests that omit queue and cancellation time;
- memory-only stability claimed as service-capacity proof;
- fake-tool success claimed as production-adapter qualification;
- cleanup that stops after its first independent failure; and
- current-revision closure claimed without the Standard-P qualification evidence.

## 4. Allowed Patterns

- concrete ADT values and captured payloads in pure unit tables;
- fake tools and fake clients at the interpreter boundary;
- deterministic simulated clocks, queues, storage, and process faults;
- real binary composition against local isolated MinIO/Vault services;
- real named validations against harness-owned infrastructure; and
- no-op production test hooks used only to expose deterministic scheduling boundaries.

## Testing Doctrine

### Standard Testing Stack

The standard stack is Cabal, `tasty`, `tasty-hunit`, `tasty-quickcheck`, `tasty-golden`,
`typed-process`, `temporary`, Pulumi, Fourmolu, HLint, and `cabal format`; deterministic concurrency
uses `io-sim` or an equivalent repository-approved simulator.

### Parser Tests

Parser tests exercise `argv -> Command` through `execParserPure`; they cover accepted and rejected
leaf-command shapes without spawning the binary.

### Pulumi-Orchestrated Infrastructure Tests

Pulumi-backed tests provision harness-owned infrastructure, execute the assertion, and register
their cleanup DAG before mutation. They use isolated stacks, ownership tags, bounded deadlines,
and fail-closed residue re-observation.

### Test Organization

Each tier remains a separate Cabal test stanza:

```text
test-suite prodbox-unit
test-suite prodbox-integration
test-suite prodbox-haskell-style
test-suite prodbox-daemon-lifecycle
test-suite prodbox-pulumi
```

`cabal test` runs the package suites. `prodbox test all` is the developer-facing orchestration
entrypoint and composes package tests with named validations; it is not a second independent test
system.

## 13. Coverage and Qualification

The local code-quality baseline remains:

- `prodbox dev check`;
- `prodbox test unit`;
- `prodbox test integration cli`; and
- `prodbox test integration env`.

Those commands prove the code-owned surfaces they actually exercise. They do not, by themselves,
qualify a changed deployed topology. A runtime-affecting revision additionally needs the exact
composition, load, chaos, cleanup, and consecutive aggregate evidence required by
[Development Plan Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

The typed evidence artifact records source revision, generated-config digest, every component image
digest, resolved topology/wiring digest, substrate, canonical commands, normalized old→new envelope
mapping, production resource envelopes, authored load profile, counterexample ID and old/new
results, complete fault matrix, operation IDs, consecutive aggregate results, cleanup/residue
result, start/completion timestamps, and evidence digest. Missing or stale fields refuse
qualification. Evidence from an older revision or a weaker topology cannot close the current
counterexample.

## Intent Ownership

This document owns testing-layer boundaries, interpreter-only mocking, deadline/load/chaos proof
requirements, and the public runner contract. It does not own suite status, process topology,
business semantics, substrate inventory, or cleanup implementation details.

## Cross-References

- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Pure Functional Programming Standards](./pure_fp_standards.md)
- [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md)
- [Resource Scaling Doctrine](./resource_scaling_doctrine.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Test Topology Doctrine](./test_topology_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Code Quality Doctrine](./code_quality.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
