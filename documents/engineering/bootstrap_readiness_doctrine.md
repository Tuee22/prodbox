# Bootstrap Readiness Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Define capability-exact bootstrap ordering and the distinct liveness, admission,
> execution, and stability observations required before a consumer may use a dependency.

Implementation status, counterexamples, and deployment-qualification evidence are owned only by
the [Development Plan](../../DEVELOPMENT_PLAN/README.md). The physical control-plane split and
operation-indexed capability types are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

## 0. Canonical Doctrine Statements

Each statement below is a numbered sub-section so that a citation such as `§ 0.7` resolves to a
heading a reader can link to. Source modules cite these by number —
`src/Prodbox/Gateway/Readiness.hs` and `src/Prodbox/Bootstrap/Broker/Readiness.hs` both cite
`§ 0.7`, and `src/Prodbox/CheckCode.hs` cites `§ 0`/`§ 2.4` — so the numbering is a contract, not
presentation. Sprint `0.21` promoted these from an ordered list, which no citation could target.

### 0.1 A dependency is an operation-scoped capability

A component name, backend label, URL, rollout, or successful command exit is not a capability. The
requirement identifies the exact operation, service identity, authority scope, and latency budget
the consumer needs.

### 0.2 Observation, admission, and execution use the same opaque reference

A caller cannot probe one endpoint and execute through another, nor attach arbitrary `IO` to a
constructor carrying a stronger label. The interpreter resolves one `CapabilityRef kind` and uses
it for all three. This is observation of that requested operation's service/session/queue
capability; a separate read-only domain observation never authorizes a mutation kind.

**Sprint `1.76` closes the gap between that statement and the implementation.** The declaration side
was enforced — the component graph's pure depth check refuses a shallow probe declared against a
`BackendWriteEdge` — but the *adapter* side was not: the deep slot of `ComponentReadinessTarget`
held an arbitrary action carrying no evidence of what it had done, so the declaration constrained a
graph and never a probe. The deep slot now has its own result type, `BackendRoundTripResult`, whose
ready arm carries a `RoundTripWitness`. A shallow probe action therefore does not inhabit the deep
slot: it is a type error, not a runtime classification something downstream has to catch.

### 0.3 Ordering is derived from pure requirements

The component graph contains capability requirements as data. It contains no executable callback. A
graph with no unique compatible provider, a cycle, a dangling provider, a scope mismatch, or no
production interpreter is not a valid plan.

### 0.4 External state is observed, not commanded

Liveness, admission, capability result, and stability are flat exhaustive ADTs projected from
authoritative observations. A GADT indexes which operation a program may request; it does not claim
that a remote transition occurred.

### 0.5 Cannot observe is never success

Unreachable, malformed, stale, wrong-scope, and deadline-expired observations keep the gate closed
and retain their structured reason.

### 0.6 Point readiness is not durable authority

A successful observation can authorize only the bounded next action through the same reference.
Long-running lifecycle work is submitted as a durable idempotent operation whose admission,
journal, execution, and result share one authority identity.

### 0.7 Lifecycle probes are constant time

`/healthz` proves process liveness. `/readyz` is a cached admission projection. Neither performs
backend I/O, serializes operational state, or claims runtime stability.

A readiness projection is only as sound as the schedule behind it. A cached record carries the
instant it was observed at, and a staleness bound older than the observer can actually meet makes
a healthy system project `Starting` and evict itself. The bound is therefore **derived from the
observer period and its per-pass budget, never authored beside them** — see
`Prodbox.Bootstrap.Broker.Readiness`.

### 0.8 Readiness includes service capacity

Memory containment alone is insufficient. A capability is not admissible when its bounded queue,
measured service rate, CPU budget, or remaining absolute deadline cannot support the request.

### 0.9 Readiness is a typed three-valued gate

An observation resolves to `ReadyObserved`, `NotReadyYet`, or `Unreachable`. `NotReadyYet` — and a
*transient*, not-yet-scraped `Unreachable` (§ 2.4) — is a **distinct non-terminal constructor**: the
"act" transition is reachable only from `ReadyObserved`, while a not-yet-ready observation keeps the
gate closed and is bounded-retried, never latched. It must never be collapsed into a
definitively-fatal bucket (the **bring-up dual**: not-ready → terminal-fail) or a definitively-absent
bucket (the **fail-open predicate**: not-ready → absent). A timed wait is a mitigation of that
illegal state, not its removal — the distinction must live in the type the fold or decision
consumes.

## 1. Failure Class

The original motivating race was registry publication through MinIO. `GET /v2/` proved that the
registry front door answered, while the next image push required the registry's S3 write path. The
first operation to exercise registry-to-MinIO DNS, credentials, and object writes therefore failed
after the shallow gate passed.

The later gateway/lifecycle counterexample was stronger:

- a gateway object GET for a deliberately absent key was labelled a backend round trip and counted
  as ready even though it did not exercise conditional write, read-back, lease, checkpoint, or
  target-delivery semantics;
- the check and subsequent operation could use different gateway endpoints and failure domains;
- all work shared a saturated gateway process, a capacity-one child-process permit, and a hard CPU
  limit;
- the server could wait for one timeout and then execute under another while the client's total
  timeout was shorter than either composition; and
- a successful point observation was used as evidence for a much longer synchronous transaction.

These are one defect class: **a weaker or differently bound observation was promoted into
authority for a stronger operation**. Longer polling, retries, or a broader “deep” label cannot
repair that mismatch.

The **inverse** defect is equally forbidden: a `NotReadyYet` — or transiently-`Unreachable` —
observation **collapsed into a terminal or absent bucket**. This is the **bring-up dual** (not-ready →
definitive fail) and the **fail-open predicate** (not-ready → absent). Two concrete instances: a gateway
runtime-stability sample latched a not-yet-scraped but healthy Pod as a terminal unreachable (poisoning
the whole run), and a host-direct object-store / lease read collapsed a transient connection-refused
into a terminal authority-unobservable / ownership-lost. In both, the not-yet-ready third value shared a
constructor with the definitive one, so nothing at the type level stopped the collapse; the correction
is a *distinct non-terminal constructor* per §2.4, enforced by `prodbox dev check`'s three-valued
readiness conformance gate.

## 2. Four Independent Observations

Do not collapse these axes into one Boolean or one `/readyz` result.

| Observation | Question | Scope |
|-------------|----------|-------|
| Process liveness | Is this process alive? | Constant-time current process fact |
| Admission | Can this exact service lane accept this operation before its deadline? | Current queue/session/capacity fact |
| Capability execution | Did this exact operation through this exact reference produce its typed result? | One bounded operation |
| Runtime stability | Did the deployed component satisfy its service and resource contract over the required interval? | Time-windowed, absorbing evidence |

### 2.1 Liveness and cached readiness

`/healthz` returns success while the process can serve its lifecycle endpoint. `/readyz` projects
only boundary-owned cached state: startup complete, not draining, required managed sessions
available, and documented admission lanes open. Both must remain independent of backend latency,
queue length scans, operational state rendering, and object-store or Vault calls.

A component may be live but not ready to admit work. Removing a saturated or degraded replica from
a capability Service is correct; blocking an unbounded number of callers behind it is not.

`Prodbox.Gateway.Readiness.computeReadiness` is the daemon's one pure readiness projection. It folds
three cached boundary facts: the terminal drain phase, current emitter authority, and the monotone
workers-started fact. `/readyz` reads and folds those facts in constant time with no backend I/O.
The former unconditional serve-start `Ready` write is deleted.

The rollback `LegacyModelBEmitter` topology installed by Sprint `2.34` preserves its historical
monotone authority latch. It sets the cached fact only in the STM transaction that publishes a
validated continuity `StartupRecovery` (a real conditional-write/read-back on first admission or an
authoritative validated GET-and-restore for a previously admitted emitter — never the absent-object
GET §2.3 forbids). The harness reaches that boundary through its fake authority interpreter; there
is no environment-variable bypass for readiness.

Sprint `2.32` completes the code-local target `JournalLeaseEmitter` topology: emitter authority is
deliberately non-monotone. `Ready` requires an identity-bound encrypted journal under its long-held
filesystem lock, a current matching Kubernetes Lease witness, completed exact recovery, and started
workers. Exact recovery normalizes every retained signed phase to the durable-stage boundary,
republishes the same signed bytes, and re-arms an interrupted Orders migration from the authenticated
prior digest before readiness. Lease loss or an expired witness clears authority and permits
`Ready → Starting`; successful reacquisition may restore readiness only after that recovery completes.
Drain remains absorbing, so no topology can
leave `Draining`. The lifecycle-restore gate additionally has a `/readyz` precheck before its
end-to-end capability round trip, so lifecycle-ready implies kubelet-ready by construction. This
closes the `F-READY` mechanism of counterexample `LCPC-2026-07-11` and absorbs the
exact-readiness-evidence deliverable rescoped from Sprint `1.61`.

### 2.2 Admission

Admission uses the exhaustive `AdmissionObservation kind` owned by
[Lifecycle Control-Plane Architecture §4](./lifecycle_control_plane_architecture.md#4-absolute-deadline-and-admission-algebra):
open with a ticket, saturated, degraded, deadline-expired, or unobservable.

The ticket is bound to capability kind, service identity, authority scope, exact coordinate,
capability-binding digest, canonical request digest, queue generation, and one monotonic absolute
deadline. It is short-lived admission evidence, not a promise of future health. Admission and
execution remain one private interpreter call, so a caller cannot pair a ticket with another
request.

### 2.3 Capability execution

The result-indexed capability program defines what was exercised. For example, an object GET may
prove only `LifecycleObserve`; it cannot satisfy `LifecycleCasReadBack`. The latter operation must
perform the conditional mutation and authoritative read-back named by that program.

Canaries, where required, use a reserved coordinate and the same client, authentication identity,
queue, transport, and interpreter as production execution. A canary through another Pod, a bare
MinIO health endpoint, or an absent-object GET is not interchangeable evidence.

Read-only prerequisites remain read-only. A mutating canary is a visible preparation or
reconciliation step, not a hidden prerequisite effect. Long-running work does not run a canary and
then open an unrelated transaction; it submits the idempotent durable operation directly.

#### A staleness bound is computed, never authored (Sprint `2.40`)

A cached readiness projection fails closed when its record is older than a staleness bound. That
bound is not free to be authored beside the observer that fills the record: the observer stamps its
record **after** a pass, so its inter-stamp interval is `period + passDuration`, and a bound that
tolerates one missed pass must be at least `2 * (period + budget)`.

The Bootstrap Broker's bound was authored as `3 * observerPeriod` = 15 s against a 5 s period and a
5 s budget, where the arithmetic requires 20 s. The failure mode is worth naming because it is not a
slow one: a broker whose dependencies are all `Ready` projects `Starting` for most of every cycle,
and `failureThreshold: 6` at `periodSeconds: 10` removes the Pod after 60 s. A healthy system evicts
itself because two constants were authored separately.

`Prodbox.Bootstrap.Broker.Readiness.ObservationSchedule` hides its constructor and derives the bound
in its smart constructor, so a bound the observer cannot meet is not constructible, and
`computeBrokerReadiness` takes the schedule rather than reading free top-level constants — the
projection enforces the bound belonging to the observer that filled the record it is folding.

#### Write-shaped evidence is minted, never asserted (Sprint `1.76`)

The rule above says an object GET cannot satisfy a conditional-write operation. Enforcing it
requires the write-shaped evidence to be unforgeable, so `RoundTripWitness` is opaque and its
constructor lives in a package-internal module whose importers are an allowlist `prodbox dev check`
enforces. The allowlist admits only interpreters that performed or authoritatively decoded a round
trip:

- the object-store conditional-write path, which now carries the version the store returned for the
  write it issued (`ConditionalPutApplied` had been discarding it) rather than reporting a bare
  "applied";
- `Prodbox.Gateway.Client`, which decodes the receipt the gateway daemon records at the instant its
  own conditional continuity write is accepted;
- `Prodbox.Lifecycle.RegistryBackendWitness`, which decodes the upload session the registry can only
  have created by writing through to its storage backend.

Two consequences are worth stating because the superseded implementation had neither:

- **A witness carries the instant the write landed, not a later clock read.** Without that the
  freshness window is inert — it bounds the age of the question rather than the age of the proof, so
  a decade-old round trip and a current one produce identical observations. The gateway daemon
  stamps the instant at the point its interpreter observes the store's acceptance, and the host's
  evidence fold uses that instant as `observedAt`.
- **A daemon that is up is not a daemon that is writing.** The gateway deep probe previously read a
  constant-time `/readyz` latch, which is exactly the object-GET case this section forbids. `/readyz`
  is retained as the liveness precondition it genuinely is, and the evidence now comes from the
  daemon's recorded round-trip receipt, refreshed on every heartbeat publication. A daemon that
  stops writing stops satisfying the edge, which is the distinction the window exists to make.

### 2.4 Dependency Readiness vs Runtime Stability

Runtime stability combines run-wide absorbing failures with a bounded consecutive-success window.
At minimum the authoritative samples cover:

- restart and termination residue, including OOM;
- memory working set and configured high-water evidence;
- CPU usage and CFS throttling;
- bounded-queue occupancy and saturation refusals;
- queue-wait, service-time, and end-to-end latency distributions;
- deadline misses and cancellation failures;
- managed-session refresh failures; and
- missing, malformed, or unreachable observations.

Restart, OOM, failure-threshold resource breach, repeated deadline breach, and unobservable
required evidence are absorbing for the run. A replacement Pod or later green sample cannot erase
them. Warning evidence resets the consecutive-success window. Only an explicitly planned rollout
may reset that success window, never the absorbing record.

A **not-yet-observable** sample is not the same as an **unobservable** one, and only the latter is
absorbing. A freshly-(re)started but healthy resource whose scrape or read-back has not yet landed — a
not-yet-scraped metrics working set, a transiently-unroutable object-store endpoint — is `NotReadyYet`
(§0.9): a distinct non-terminal observation that resets the success window and is bounded-retried,
never latched. Only *persistently* unobservable required evidence (still unobservable past the bounded
readiness budget) or a static wrong-scope / policy mismatch is absorbing. Collapsing the transient case
into the absorbing one is the bring-up-dual defect (§1); the fix routes each transient case through a
distinct non-terminal constructor (`GatewayObservationIncomplete`, `ModelBEndpointUnready`,
`LeaseAuthorityEndpointUnready`) that the fold or lease monitor cannot promote to fatal.

The old restart/OOM/memory-only classifier is a useful subset, not sufficient proof of capability
stability. CPU throttling, queue pressure, and latency are mandatory because a memory-safe process
can still be computationally unable to meet its contract.

## 3. Making the Class Unrepresentable

### 3.1 M1 — Derive ordering

The plan compiler obtains dependencies-before-consumers order from a validated acyclic graph.
Narration and execution consume the same compiled order. Hand-written order lists may implement a
generic fold, but they are not an ordering authority.

Clean bootstrap begins with `prodbox config setup` as a Tier-0 author/validator and optional
read-only AWS discovery step. It cannot create IAM/S3/DNS state. `cluster reconcile` then exposes
Vault init/unseal, `EstablishAuthorityBackup`, config seeding, and normal operator-material actions
as ordered visible plan nodes. Before first `/sys/init`, the Broker must read back the
password-AEAD `PreparedInitEnvelope` for the exact empty storage generation; a fingerprint alone
does not satisfy that edge. A prompt, IAM create, S3 write, or TLS issuance hidden in a
prerequisite/readiness observer is a graph violation.

Graph construction rejects cycles, dangling requirements, duplicate exclusive providers, scope
mismatches, and missing interpreters before mutation. Substrate-specific capabilities name their
substrate explicitly; there is no home/AWS fallback.

### 3.2 M2 — Store requirements, not probes

Tier-0 configuration declares which capability each component provides and requires. It does not
select a probe implementation or carry an executable action. The canonical
`CapabilityRequirement kind` includes the exact `CapabilityCoordinate kind`, and
`SomeCapabilityRequirement` carries its singleton witness; both are owned by
[Lifecycle Control-Plane Architecture §3.3](./lifecycle_control_plane_architecture.md#33-capability-requirements-in-the-component-graph).

Runtime reconnaissance resolves that value into an opaque `CapabilityRef kind`. Smart
constructors validate the service identity, substrate, authority epoch, transport binding, and
coordinate bounds. The graph cannot construct the reference and cannot smuggle `IO` into it.

The former gateway-pre/gateway-full node split is superseded. The Bootstrap Broker is the
pre-Vault component; the Gateway Runtime starts only after Vault and its identity-bound continuity
journal are available. Lifecycle Authority, home Authority Backup Adapter, home Provider Worker,
TLS Retention Adapter, and each Target Secret Agent are independent providers, not phases of
gateway readiness. Normal Authority mutation additionally requires the exact fresh
`AuthorityBackupCommitReadBack` provider/session; `GenesisFrozen` or `BackupRepairFrozen` cannot be
reported ready for normal work. Credential Provisioner/Admin Action Runner readiness is permit-
specific Pod UID/image/ServiceAccount attestation, never a standing component label.

The AWS projection validates the complete role/transport registry before its first platform
effect. Its readiness order is capability-first: EKS Broker and target transports, retained-home
Authority transport, Provider Worker registration, target-local DNS01 generation/read-back, then
cert-manager issuer admission and controller-owned public edge. A Gateway-ready observation cannot
satisfy any Authority, Provider, or Target-Agent prerequisite.

The Broker is selected as a distinct runtime role by `prodbox bootstrap-broker start` with
`--config <path>`. Its role-only document and loopback listener cannot be substituted with Gateway config or
a generic endpoint. Until the physical adapters and workload rendering owned by Sprint `3.26`
exist, the production boundary may report process liveness but keeps readiness and every
non-health capability closed; a deterministic fake proves composition without becoming a
production selection path.

Backup state is total: established/current may admit, positive permanent loss may select only the
visible `BackupRepairFrozen` protocol, and temporary/unreachable/malformed/stale observation keeps
the gate closed. TLS readiness is likewise operation-exact. Restore/retention resolves the TLS
Retention Adapter plus the selected Agent's exact `TlsSecretObserve`/`TlsSecretSeal`/
`TlsSecretMaterialize` lanes; home key exchange additionally resolves the home Agent's separate
`TlsEnvelopeKeyExchange` lane. Positive absence or policy-valid expiry may select issuance, while
corrupt, mismatched, rollback, or unobservable TLS state never becomes “missing.”

### 3.3 M3 — Index programs by operation

Capability programs are the closed GADT owned by
[Lifecycle Control-Plane Architecture §3.2](./lifecycle_control_plane_architecture.md#32-programs-are-data).
The target coordinate appears only in `CapabilityRef kind`; the program carries the canonical
operation payload, and mutating internal programs additionally require the matching opaque writer
permit or committed-intent reference.

`runCapability` receives the resolved reference, absolute deadline, and compatible program. A
target-secret reference cannot run a lifecycle CAS program; an observe-only reference cannot run a
conditional write; and a probe endpoint cannot be supplied separately.

For Bootstrap Broker, one strict `Protocol` decodes the method/route/body into the closed operation
and one `Engine` prepares its GADT program. `brokerProgramCapabilityRef` exhaustively selects the
same `CapabilityRef operation` used by admission and execution, so a route/program mismatch is a
type error rather than a runtime label. Mutation admission is still not execution authority: every
Vault effect and custody/journal-store transition also requires its own opaque permit minted from a
fresh matching durable fence and Kubernetes Lease observation; fence acquire/retire uses an exact
CAS plan and read-back. Expired-owner cleanup and exact CAS retirement must complete before a
successor reference can execute a new fence generation.

The same index separation applies to private roles: `AuthorityBackupCommitReadBack` cannot execute
TLS-prefix work; `TlsRetentionCommitReadBack` cannot address Authority backup; Provider apply cannot
accept a genesis/repair/operator-material or admin-action permit; and Credential Provisioner cannot
accept an Admin Action permit. Raw prompt/credential bytes travel over a separately authenticated
linear ingress after attestation and therefore are not readiness inputs or serializable programs.

`ReadinessObservation` remains a flat external projection over the three-valued constructor set
`ReadyObserved | NotReadyYet | Unreachable` (§0.9): only `ReadyObserved` opens the gate, and
`NotReadyYet` / a transient `Unreachable` is retained as a distinct non-terminal state, never folded
into ready or into a definitive failure. The GADT proves only that an attempted program is legal for
the reference kind. The interpreter's typed result and fresh observations prove what the external
system actually did.

## 4. Absolute Deadlines, Retry, and Cancellation

One monotonic absolute deadline covers admission, queue wait, credential refresh, external I/O,
read-back, result persistence, response serialization, and bounded cancellation. Every child
receives the remaining budget; no nested relative timeout may restart the clock.

Retry is allowed only when:

- the failure constructor is classified as transient;
- the operation is idempotent or has a durable operation ID/fence;
- the next attempt fits inside the original deadline; and
- retry does not hide saturation that should produce a typed admission refusal.

A transport timeout is an ambiguous result, not proof of failure. Durable control-plane calls
resolve ambiguity by operation ID and authority observation. Non-durable request work is canceled
when its caller disappears; durable work may continue only after its intent was committed and can
be observed independently of the original connection.

## 5. Verification Obligations

The capability/readiness design is incomplete without all of these layers:

1. **Pure tables and properties**: every capability kind/program match, graph rejection,
   observation fold, admission decision, absolute-deadline calculation, retry classification, and
   absorbing stability result.
2. **Deterministic concurrency simulation**: queue saturation, cancellation, response loss,
   restart, stale fence, and actor interleaving through `io-sim` or an equivalent scheduler.
3. **Production-adapter composition**: real binary, native MinIO conditional write/read-back,
   renewable Vault session, exact service identity, actual configured cgroups, and for Bootstrap
   Broker the rendered TokenReview/Lease/one-shot-workload/OpenPGP boundary with persistent
   receipt/session/accessor cleanup.
4. **Load qualification**: authored background rates plus burst, CPU throttling, queue wait,
   deadline misses, and p95/p99 latency with declared headroom.
5. **Chaos qualification**: restart or isolate Gateway Runtime, Lifecycle Authority, Backup/TLS
   Adapters, Provider Worker, Credential Provisioner/Admin Action Runner, Target Secret Agent,
   primary MinIO, backup S3, and Vault at every durable transition boundary; prove resume, frozen
   repair, or typed refusal. Each has its own admission lane, managed-session, capacity, and
   stability evidence; another component's green probe cannot substitute.
6. **Cleanup qualification**: inject failure at every cleanup-DAG node and prove independent work
   continues, root cause is retained, all cleanup failures aggregate, and residue is re-observed.

Passing unit tests or a point probe does not qualify a deployment revision. Current-revision
deployment qualification and counterexample closure are governed by
[Development Plan Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

## 6. Intent Ownership

This document owns capability-exact bootstrap ordering and the distinctions among liveness,
admission, execution, and runtime stability. It owns the **typed three-valued readiness gate** (§0.9,
§2.4): a not-yet-ready observation is a distinct non-terminal constructor, the "act" step is reachable
only from a proven-ready state, and neither the bring-up dual (not-ready → fatal) nor the fail-open
predicate (not-ready → absent) is representable.

It does not own process topology, authority workflow, target-delivery protocol, exact resource
thresholds, test-suite membership, sprint status, or deployment evidence. Those remain in their
linked SSoTs.

## 7. Cross-References

- [Chaos Hardening Doctrine § 21](./chaos_hardening_doctrine.md) — the eight coordinates a decision
  needs on the value it decides from. § 0.5 here is the *Distinguishability* class stated as
  doctrine; the four-valued observation shape that satisfies it is
  `Prodbox.Bootstrap.Broker.Readiness.BrokerDependencyObservation`, whose absorbing
  identity-rejection constructor is the point — a dependency refusing this workload's credential is
  not a dependency that is still coming up.
- `Prodbox.Lifecycle.CapabilityReadinessBarrier` is the production implementation of § 0.2's
  same-reference rule: it resolves one `CapabilityRef`, classifies the observation, and mints the
  admission ticket. Its evidence constructors are the *Provenance* class in
  [§ 21](./chaos_hardening_doctrine.md) — a witness must be returned by performing the operation,
  never synthesized from a description of it.
- [chaos_hardening_doctrine.md § 23](./chaos_hardening_doctrine.md) — the rule that a refusal
  retains its structured reason (stated in section 0.5 above) does not stop at a region edge. A
  typed refusal converted into an exception, and then into an unanswered socket, is the same
  collapse this doctrine forbids at an observation seam, committed one layer out.
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) — capability
  GADT, same-reference rule, physical service split, deadlines, and durable operations.
- [Pure FP Standards](./pure_fp_standards.md) — external `decide`/`evolve` folds and interpreter
  boundaries.
- [Resource Scaling Doctrine](./resource_scaling_doctrine.md) — CPU, service-rate, queue, memory,
  and runtime-stability proof obligations.
- [Unit Testing Policy](./unit_testing_policy.md) — composition, load, chaos, and cleanup-DAG test
  requirements.
- [Prerequisite Doctrine](./prerequisite_doctrine.md) — read-only prerequisite/preparation split.
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md) — external
  observations and fail-closed reconciliation.
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md) — Gateway Runtime
  scope and constant-time lifecycle endpoints.
- [Local Registry Pipeline](./local_registry_pipeline.md) — registry-to-MinIO worked example.
- [Development Plan](../../DEVELOPMENT_PLAN/README.md) — status and qualification evidence.
