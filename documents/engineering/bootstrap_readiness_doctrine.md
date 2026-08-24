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

#### 0.4.1 The worker-image corollary: what is proven and where to look are different values

The Bootstrap Broker launches its secret worker from the controller's own image, and § 0.4 decides
*which* of the image's identities carries which obligation.

A container image has two sha256 identities and they are the same sixty-four lower-hex characters:
the **config digest** the container runtime reports as `status.containerStatuses[].imageID`, and the
**manifest digest** an OCI registry can resolve. They are indistinguishable by syntax and
distinguishable only by which endpoint answers them, so the separation cannot live in a smart
constructor over the digest text — see
[local_registry_pipeline.md § 6.2](./local_registry_pipeline.md) for the pipeline half and
[chaos_hardening_doctrine.md § 24](./chaos_hardening_doctrine.md) for the general shape.

The doctrine assigns them as follows:

- **The attestation identity is the observed runtime digest.** A worker Pod is the controller's own
  image exactly when the worker's observed `imageID` equals the controller's observed `imageID`.
  This is an *observation* of what the kubelet actually ran, and it is what § 0.4 requires.
- **The Pod spec's `image` field is a request, not a proof.** It carries the controller's *declared*
  reference — whatever the kubelet can resolve, which for a locally built image is a mutable tag.
  A digest in a Pod spec commands; it does not observe.

Two consequences follow, and both are stronger than pinning the spec:

1. A digest-pinned Pod spec never proved the worker matched the controller — only that the kubelet
   did not ignore the spec. Requiring the two Pods' observed runtime identities to agree subsumes
   that, because it compares against an independently pinned expectation rather than against a value
   the same spec supplied.
2. Pinning the spec to a **config** digest proves nothing at all, because no kubelet can resolve it;
   the Pod never starts. A refusal that no run can reach is not a check.

The declared reference is re-observed at Pod creation rather than recorded in the durable worker
intent. It is an addressing hint whose correct value can change with a redeploy, not part of the
binding the intent commits to; the creation boundary additionally refuses when the freshly observed
runtime digest no longer equals the one the intent pinned.

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

The post-unseal sequence has separate terminal edges. The unseal worker closes on its exact
validated receipt and the baseline root/provisioner session closes on its exact read-back without
contacting a not-yet-installed consumer. The native plan then reaches Target Secret Agent rollout,
Lifecycle Authority rollout, and the explicit `reconcile_post_unseal_handoff` transition in that
order. Only that last fixed-coordinate Broker mutation may drive Authority acceptance and exact
read-back into the durable handoff journal. Narration and APPLY project all three post-Vault steps
from the same step table; neither unseal nor baseline hides the later handoff effect.

The generated-root ciphertext needed by first-baseline is itself secret-worker work. The controller
mints the `BootstrapVaultSubmitGenerateRootShare` permit in the root-session scope, then drives
`SecretWorkerCompleteGeneratedRoot` through the same fenced, attested, checkpointed one-shot
boundary before the PGP scope may decrypt the returned ciphertext. A constructor whose
`physicalCallSecretWorkerOperation` is present must never enter the direct physical interpreter;
that interpreter's refusal is a guardrail, not an alternate execution lane.

The generated-root PGP boundary reports failures as a closed payload-free algebra. Only the
protected baseline-route diagnostic may render its stable cause: session/action kind, the exact
action substage, and for core reconcile the closed Vault operation plus connection/timeout/numeric
status/decode or typed drift/secret-bootstrap class. PKI reconciliation and observation likewise
use separate closed operation vocabularies for issuer listing, internal-root generation, role write,
issuer read-back, and role read-back; nested observation failure and non-exact absent/drifted/ready
status remain explicit. The public response remains the generic state conflict, and unrelated routes
render no PGP cause. Vault bodies, exception messages, request context text, key/path/role names,
tokens, ciphertext, and secret-bootstrap values cannot inhabit the diagnostic type. A new PGP
action, root-action substage, Vault reconcile/PKI error, HTTP operation, or nested CAS outcome
therefore requires an exhaustive classifier before the build succeeds.

Root-accessor absence is an explicit physical requirement, not a prose convention. Stable-zero
transitions require the complete observed root-policy inventory to be empty; current-accessor
transitions require only the exact journaled target accessor to be absent. The proof first requires
the observation and target inventories to carry the same storage generation and refuses when any
target remains. Its protected baseline diagnostic uses a closed payload-free cause for projected
token availability, auditor login/list/lookup HTTP class, invalid bounded-batch login cleanup,
malformed accessor/inventory observation, generation mismatch, target presence, or stable-zero
mismatch. HTTP bodies, accessors, tokens, paths, and exception text cannot inhabit that cause. The
public response remains the generic boundary refusal or availability class, and unrelated routes
render no exact absence cause. Vault's LIST-accessors HTTP 404 is the one non-success response that
denotes an empty accessor collection and therefore supplies an empty inventory; connection failure,
timeout, every other numeric status, and decode failure remain closed refusals.

Root-accessor revocation is a separate physical boundary from its later absence proof. Its
protected baseline diagnostic carries a closed payload-free cause for projected-token availability,
bounded auditor login and invalid-login cleanup, the revoke HTTP operation, the immediate list
read-back HTTP operation, or the exact target still being present. Connection failure, timeout,
numeric status, and decode failure remain distinct without retaining their bodies. The public reply
still exposes only the generic unavailable, ambiguous, or refused class, and an unrelated route
never renders the revocation cause.

Root-accessor inventory likewise has its own closed physical-boundary cause. Its protected baseline
diagnostic distinguishes projected-token availability, bounded auditor login and invalid-login
cleanup, list and per-accessor policy-lookup HTTP operation/class, malformed root accessor, and
inventory size/uniqueness refusal. Accessor and policy values, response bodies, tokens, paths, and
arbitrary text cannot inhabit the cause. The exact cause is rendered only for the protected
baseline route; public and unrelated-route responses retain their generic class. An inventory call
owns its empty-collection decision independently from the absence proof: only LIST HTTP 404 supplies
an empty inventory, while connection failure, timeout, every non-404 status, and decode failure
retain their exact closed refusal.

Provisioner-accessor cleanup is a separate stable-zero boundary with its own closed payload-free
cause. It distinguishes projected-token and bounded-auditor login/invalid-login cleanup, the
initial role-wide list and subject lookup, the audit's repeated list/lookup/revoke/direct-absence
operations, visibility refusal, malformed accessor/inventory observations, and exhaustion of the
finite stable-absence proof. The provider operation and connection/timeout/numeric-status/decode
class are retained, but roles, subjects, accessors, tokens, paths, bodies, and arbitrary error text
cannot inhabit the cause. A revoke response is always provisional: success, failure, or response
loss neither closes nor fails cleanup by itself; only later authoritative observations decide the
terminal result. The exact cause is rendered only on the protected baseline route, while public
and unrelated-route replies retain their generic unavailable, ambiguous, or refused class. Both
the initial and repeated role-wide LIST operations share one empty-collection decision: exact HTTP
404 supplies an empty inventory, while connection failure, timeout, every other numeric status,
and decode failure retain their closed cause.

Provisioner-policy application is a distinct physical boundary after cleanup and login. Its
protected baseline diagnostic carries one closed payload-free cause for a missing process-local
provisioner token, the complete core Vault reconcile error sum, or the complete PKI reconcile and
read-back error sum. The core and PKI projections are the same exhaustive types and classifiers
used by the generated-root lane: every HTTP operation and
connection/timeout/numeric-status/decode class, typed drift, nested secret-bootstrap CAS outcome,
PKI observation failure, and non-exact PKI status remains distinguishable without duplicating a
second interpretation. Tokens, paths, names, policy/secret material, response bodies, and
free-form text cannot inhabit the cause. Only the protected baseline route renders it; unrelated
routes do not, and every arm retains the pre-diagnostic generic HTTP 503
`boundary-unavailable` response until live evidence licenses a behavior change.

Provisioner-accessor revocation is distinct from cleanup, policy application, and root-accessor
revocation. Its target protected diagnostic carries a closed payload-free cause for bounded-auditor
login and invalid-login cleanup, the initial accessor inventory, target lookup and subject
verification, the revoke HTTP operation, the authoritative post-revocation inventory, and exact
target/role absence status. Connection failure, timeout, numeric status, and decode failure remain
separate without retaining accessors, subjects, roles, tokens, paths, response bodies, or arbitrary
text. The public response remains generic. The current production interpreter still collapses
these outcomes; adoption is scheduled in
[Sprint `2.75`](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md#sprint-275-provisioner-accessor-revocation-needs-an-exact-cause),
with current status owned only by the development-plan resumption ledger.

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
`--config <path>`. Its role-only document and loopback listener cannot be substituted with Gateway
config or a generic endpoint. Completed Sprint `3.26` supplied chart/render foundations, but the
production boundary still reports only process liveness and keeps readiness and every non-health
capability closed; a deterministic fake proves composition without becoming a production selection
path. Physical adapter activation and cutover status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here).

Host access preserves that loopback boundary at both ends. Before minting the short-lived
TokenRequest credential or starting `kubectl port-forward --address 127.0.0.1
service/bootstrap-broker`, the host client observes the exact Broker Deployment rollout through the
same explicit namespace, kubectl environment, and working directory. Starting a Service
port-forward while its replacement Pod is still Pending can make kubectl exit immediately; retrying
HTTP against the now-dead local socket is not a readiness wait and must not be represented as one.
A rollout timeout or refusal is therefore a distinct pre-transport outcome.

Controller image self-observation uses the chart's exact controller selector, not an application
name shared by every Broker-owned Pod. The query requires both
`app.kubernetes.io/name=prodbox-bootstrap-broker` and the supported release instance
`app.kubernetes.io/instance=bootstrap-broker`. A retained or running one-shot worker deliberately
lacks the instance label and cannot contaminate the controller PodList. The observer still refuses
zero or multiple matching controller Pods; narrowing the selector does not license choosing an
arbitrary replica.

Expired-fence retirement distinguishes a live worker process from a terminal Pod object. Only an
exact same-generation Pod whose API-owned UID is valid and whose phase is `Succeeded` or `Failed`
may enter terminal-owner cleanup. The Broker deletes it with that UID as a Kubernetes precondition
and obtains a later exact 404 before deriving owner absence. Pending, Running, Unknown, malformed,
foreign-generation, unauthorized, or unobservable observations authorize no delete. A
foreign-generation Pod at the one fixed coordinate still proves the queried generation absent, but
is never deleted on that predecessor's behalf.

The controller and its attested initialization worker classify the retained root journal through one
pure observation. A missing object and a present exact `RootInitPristine` are equivalent evidence of
the current generation's pristine state; `RootResetPristine` carries its reset provenance and admits
only when its replacement proof is the same derived proof. No progressed or ambiguous phase is
lowered to pristine. This classifier is shared because two independently authored predicates over
the same journal once gave opposite answers and made the preserved root permanently unstartable.

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

#### 3.3.1 Expired-owner retirement (Sprint `2.47`)

The paragraph above — *expired-owner cleanup and exact CAS retirement must complete before a
successor reference can execute a new fence generation* — described behaviour the implementation did
not have. `decideBootstrapFenceRetire` existed with its store half wired and **zero production
callers**, so a fence abandoned by a failed bring-up refused every later acquisition permanently.
Sprint `2.47` closed that gap; this section records the resulting contract so the next reader is not
left to re-derive it from the wiring.

**Three independent facts, each refusing closed on ambiguity.** Retirement produces a CAS plan only
when the predecessor's durable deadline elapsed on a *trusted* authority clock, its exact Lease is
absent or expired, and its owner cleanup was read back absent. An unreadable clock, an unreadable
Lease, and an unreadable cleanup each refuse. In particular, *cannot determine* is never expiry:
`PredecessorLiveness` is three-valued for precisely this reason, because the moment a positive expiry
authorizes a retirement, a `Bool` would let an unreadable clock authorize one too.

**The cleanup observation is scoped by fence generation, and the scope is checked in both
directions.** The predecessor's pod UID, session id, session accessor, and receipt digest are not
recoverable from the durable record that survives it, so an absence claim is keyed by the one
identity the fence does carry. An observation answering about generation `G'` is refused as
unobservable when retiring generation `G`, whichever way the mismatch points — an answer about a
different subject is never consumed as an answer about this one
([chaos_hardening_doctrine.md § 24](./chaos_hardening_doctrine.md)).

**Absence is whole, not sampled.** The Broker's secret worker is one fixed Pod coordinate, built by a
closed native manifest builder and granted by that exact name in the Broker's Role. At most one can
exist, so a Pod carrying a *different* fence generation is itself proof that this generation's worker
is gone. Every other answer — unparseable body, missing or non-canonical annotation, rejected
identity, any other status, transport failure — is unobservable. Absence is the only outcome that can
authorize a takeover, so it is the only one that must be positively proven.

**A terminal worker is cleaned as terminal, not treated as live forever.** A `Succeeded` or `Failed`
Pod carrying the queried fence generation is UID-precondition deleted and the fixed coordinate is
read back absent before retirement consumes an absence observation. Pending, Running, Unknown,
malformed, foreign-generation, and unobservable Pods are not deleted on that generation's behalf.
Kubernetes' termination wire requires `exitCode` but permits the termination-log `message` to be
absent; absence of that optional message does not make the Pod unreadable and also cannot satisfy an
operation's exact receipt binding.

**Controller self-observation distinguishes live candidates from retained terminal history.** The
exact name/instance label conjunction defines controller membership, then positively observed
`Succeeded` and `Failed` Pods are excluded before cardinality is enforced. Exactly one nonterminal
candidate must remain. Pending, Running, Unknown, and deleting candidates are never inferred absent;
their existing state checks decide whether the sole candidate is usable, and multiple such candidates
remain an ambiguity. Decoding remains whole-list fail-closed, so a malformed historical item cannot
be silently discarded as if it were terminal.

**Worker-side effect permits require worker-side Lease observation.** Reconstructing the fixed Pod
binding is insufficient: immediately before each Vault or retained-store effect, the worker reads
the durable fence and the named Kubernetes Lease and authorizes the effect only when both match its
immutable request. Its ServiceAccount therefore has `get` on exactly `bootstrap-broker-fence` in
addition to `get` on exactly `bootstrap-secret-worker`. Lease create/update/delete, Pod mutation,
TokenReview, exec/attach, and Secret reads remain controller-only or absent.

**Ambiguity recovery is liveness-gated because readiness is the state being repaired.** Ordinary
host clients wait for the exact Broker Deployment rollout before credential minting or
port-forward startup. `reset-ambiguous-initialization` is the sole exception: a durable ambiguity
intentionally withdraws `/readyz`, so requiring Deployment readiness would make the typed recovery
route unreachable. Its closed connector skips only that rollout barrier and still reserves a
loopback port, mints the exact custom-audience TokenRequest credential, forwards only the compiled
Service named port on `127.0.0.1`, proves authenticated `/healthz`, bounds retries, and bracket-cleans
the subprocess. No caller-selectable mode weakens another route.

**Recovery diagnostics are closed and payload-free.** The physical ambiguity-reset interpreter
returns a `VaultStorageResetFailure` stage algebra rather than free-form Kubernetes detail. Only
that recovery route may append its rendered stage to the Broker diagnostic, and the renderer admits
only constructor names plus a numeric HTTP status for a refused reset-Pod request. Kubernetes
bodies, object values, credential detail, controller-authored bindings, and storage identities do
not inhabit the algebra; the authenticated client still receives only the generic
`boundary-unavailable` response.

**Zero-scale recovery follows the Kubernetes Scale wire.** The fixed Vault StatefulSet is scaled
through an exact `autoscaling/v1` Scale GET and resource-versioned PUT. Kubernetes applies Go
`omitempty` to the desired replica field, so `"spec": {}` is the canonical observation of zero,
not a malformed response. The decoder defaults only that omitted field to zero; API version, kind,
name, namespace, non-empty resource version, non-negative explicit counts, and exact post-write
read-back remain mandatory before the reset program advances.

**Applied initialization ambiguity names only a closed failure class.** If Vault is already
initialized before the worker's call, or if the call fails and a separately authorized seal-status
read-back proves initialization was applied, the one-shot result carries exactly one of:
already-observed, connection failure, timeout, numeric HTTP status, or response-decode failure.
Exception strings, response bodies, prepared-recipient material, ciphertext, and credentials do not
inhabit that algebra. The classified result is an appended durable constructor; the former nullary
constructor retains its exact CBOR encoding and decodes as `unclassified`, so retained worker
checkpoints stay readable. The engine carries the class only to the protected initialization-route
diagnostic. It does not add the class to `InitAmbiguity` or otherwise reshape the durable root
journal, and the authenticated client still receives only the generic `state-conflict` response.
Re-entry from a journal that cannot retain the transient class is explicitly `unclassified`, never
an invented diagnosis.

**Vault initialization's redundant share encodings are one checked value, not two authorities.**
The documented response carries `keys` plus `keys_base64` for Shamir shares, or `recovery_keys`
plus `recovery_keys_base64` for recovery shares. The Broker admits exactly one complete family only
when both arrays are non-empty, equal in length, canonical lowercase hexadecimal/canonical base64,
and pointwise decode to the same encrypted bytes. A missing half, disagreement, mixed families, or
additional field refuses. The hexadecimal projection is discarded inside the parser; only the
existing opaque redacting share values and burn-token ciphertext cross the wire boundary or enter
durable custody. No raw-share field gains a printable or persistent representation.

**What retirement does and does not prove, stated rather than implied.** It proves the predecessor's
worker Pod is gone. It does **not** prove that a Vault session the predecessor held is gone, and
nothing short of widening the durable fence could. It does not need to: every Vault effect and every
durable mutation re-reads the exact fence through its permit minter immediately before acting, so
**retiring the fence is the revocation**, not merely what precedes it. A predecessor that somehow
survives fails closed at its next effect on a lost or stale fence. The three facts establish that the
predecessor is finished; the per-effect recheck is what makes it safe to have been wrong.

**Re-acquisition is one bounded pass.** The successor re-decides against the confirmed
post-retirement read-back rather than a fresh store read, and the bound is structural — the
re-acquire path has no route back into retirement — so a predecessor that survives the CAS refuses
instead of looping.

#### 3.3.2 The fence Lease's TTL is derived, and it expires on purpose (Sprint `2.48`)

The Kubernetes Lease is the fence's **liveness witness**, never the binding constraint on a single
request. Fence use is bounded by `min attemptDeadline leaseDeadline`, and the Lease is stamped
`renewTime = now` *after* the request carrying it was accepted, so the invariant that keeps the
`min` from ever selecting the Lease is

```text
1000 * leaseDurationSeconds >= maximumBrokerRequestDeadlineMilliseconds
```

That relationship is **derived with one owner**, not satisfied by two modules happening to name the
same number. A budget raised without the TTL following would otherwise make every long operation fail
closed on what looks like a Lease defect.

**The Lease is deliberately not renewed, and this is a safety property rather than an omission.**
§ 3.3.1's retirement takes over an abandoned fence only against a **positively expired** Lease, and
the state it exists to recover from is a bring-up abandoned partway. A renewer outliving the wedged
operation would hold the Lease live indefinitely, no successor could ever retire the fence, and the
permanent wedge § 3.3.1 closes would return. For the same reason the derived TTL is the *tightest*
value satisfying the invariant: a longer one only delays the instant a successor may act.

#### 3.3.3 An acquisition that cannot establish its Lease releases the fence it created (Sprint `2.48`)

Acquisition is two steps — CAS the durable fence, then establish the Lease — and a failure at the
second step must not leave the first standing. The compensating release is an **exact-value CAS back
to vacant with the released generation as the high-water floor**, so the generation is burned rather
than reusable and a fence this call did not write can never be vacated by it.

**It requires no observation of an owner, and that is the point.** Retirement must prove three things
about a predecessor it cannot see. This releases a fence created moments earlier by the same call, on
a path where no Lease witness was obtained — and since every effect permit requires a confirmed
witness, a fence that never carried one cannot have authorized anything. Retirement could not serve
here in any case: it requires the durable operation deadline to have elapsed, and a freshly acquired
fence's has not.

Only a **freshly CAS'd** fence may be released this way. A resumed fence pre-existed the call, and an
earlier attempt of the same request may already have confirmed its Lease and run effects under it.
The release is best-effort and never masks its cause: the original Lease refusal reaches the caller
either way.

#### 3.3.4 A pre-receipt checkpoint from a superseded generation is rolled, not refused (Sprint `2.50`)

The durable secret-worker checkpoint may resume only under an identical
operation/fence/action/request/storage/deadline binding, with exactly one exception, bounded three
ways:

1. **The checkpoint carries no result.** Only the pre-receipt constructors qualify — those whose
   receipt and result are both absent by construction. A checkpoint that carries a receipt is a
   *result* record mid-cleanup, and its cleanup binding names a Pod UID, session id, and session
   accessor no successor can reconstruct; discarding one could leak a live Vault session. Those are
   refused on every binding.
2. **The stored fence generation is strictly older than the one held.** Not "some compared field
   differs". Within one generation the identical-binding requirement is unchanged, because the worker
   operations of one bootstrap session are ordered and discarding an interrupted predecessor could
   skip a stage. A checkpoint from a *newer* generation is refused outright: that would mean the
   reader is the stale party.
3. **The predecessor's worker is destroyed, not observed absent.** The discard is a
   UID-preconditioned delete followed by an absence wait, refusing if a replacement occupies the
   fixed coordinate. This is strictly stronger than § 3.3.1's absence observation — it causes absence
   rather than inferring it — and holding the current fence is what makes causing it safe.

Without this, a bring-up abandoned after its first worker was created left a durable checkpoint no
later invocation could match, because fence generation, owner nonce, **and** the operation deadline
are all minted per invocation by construction. The replay hazard is unaffected and remains gated
where it was: whether an un-receipted worker may be re-prompted at all is decided by the interruption,
and a refusing interruption never reaches this arm.

**Binding refusals name their site and their disagreeing fields.** One payload-free constructor
covering five distinct comparisons is the § 0.5 failure in miniature — *cannot observe is never
success* has a sibling in *cannot distinguish is never a diagnosis*. Field **labels** carry no value
bytes, so the naming introduces no disclosure surface.

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
