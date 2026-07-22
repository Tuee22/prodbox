# Distributed Gateway Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md, DEVELOPMENT_PLAN/phase-0-planning-documentation.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, documents/documentation_standards.md, documents/engineering/README.md, documents/engineering/bootstrap_readiness_doctrine.md, documents/engineering/cluster_federation_doctrine.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/haskell_code_guide.md, documents/engineering/lifecycle_control_plane_architecture.md, documents/engineering/local_registry_pipeline.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/pure_fp_standards.md, documents/engineering/secret_derivation_doctrine.md, documents/engineering/storage_lifecycle_doctrine.md, documents/engineering/streaming_doctrine.md, documents/engineering/tla/README.md, documents/engineering/tla_modelling_assumptions.md, documents/engineering/unit_testing_policy.md, documents/engineering/chaos_hardening_doctrine.md, documents/engineering/pulsar_messaging_doctrine.md, documents/engineering/resource_scaling_doctrine.md
**Generated sections**: none

> **Purpose**: Define prodbox's peer-to-peer election/replication architecture using shared Orders,
> bounded semantic replica state, signed delta/cursor anti-entropy, an encrypted identity-bound
> local emitter journal, and formally constrained gateway leadership rules.

---

## 0. Canonical Doctrine Statements

Partition semantics for gateway leadership and DNS write gating must be formally verified by TLA+ before implementation changes are accepted.

For this Byzantine-generals-class failure mode, TLA+ model checking is the primary completeness tool; runtime tests validate model-to-code fidelity but are not exhaustive proofs.

Gateway timing contract is explicit: heartbeat_timeout_seconds in [3, 60], isolation_timeout_seconds = heartbeat_timeout_seconds, heartbeat_interval_seconds <= timeout/2, reconnect_interval_seconds <= timeout, and sync_interval_seconds <= timeout*2.

Gateway runtime state is bounded by construction. Heartbeats retain only the newest accepted value
per Orders member, and ownership retains only the newest accepted claim/yield evidence per member.
Signed replay, the fixed diagnostic-digest ring, transport frames, decoded batches, and in-flight
work each have configured finite bounds. A signed assertion advances this semantic state;
it is not an obligation to retain every historical heartbeat forever.

Orders membership is itself bounded input. Raw Orders bytes, member count, node-id/endpoint/key
field bytes, and the encoded per-member contribution all have validated maxima before maps,
snapshots, or peer tasks are built. Snapshot and state bounds derive from `max_members`, never from
an unconstrained `nodes[]` length supplied by Dhall.

Peer synchronization exchanges bounded deltas from a monotonic receive-cursor vector keyed by
emitter, with a bounded snapshot repair when a cursor component falls outside the retained replay
window. Sending the complete
historical event set on every interval is forbidden.

Each emitter cursor is a fixed-width `(epoch, sequence)` value. One actor per daemon exclusively
owns the local emitter transition and an encrypted, identity-bound retained journal containing the
admission/incarnation, active Orders anchor, committed epoch/sequence/previous-emitter-digest
anchor, at most one exact staged assertion, a bounded contiguous retained committed suffix, and a
bounded peer-ack/authenticated-checkpoint-floor projection. Before publishing any assertion, that actor
performs `stage -> fsync -> publish -> commit -> fsync`; epoch rotation uses the same serialized
protocol with a signed invalidation. Heartbeats never perform a shared remote Model-B transaction,
call Vault, or call MinIO. A renewable Vault session supplies the journal key at startup, and
plaintext exists only in bounded memory. Remote Model-B continuity is a migration adapter only.
Local emitter recovery reads only the authenticated journal floor, contiguous suffix, and retained
in-flight projection for that same emitter. Peer checkpoint/suffix repair updates a lagging remote
replica only; it never reconstructs or advances the local emitter journal and is never the source
of an emitter's continuity coordinates. A simultaneous restart of every peer therefore recovers
every emitter's safe continuation anchor, not the discarded semantic history.
Missing, corrupt, or unobservable journal state after admission is fail closed — the daemon may serve diagnostics and
ingest bounded peer state, but it cannot initialize or advance an emitter, claim ownership, or
write DNS. Sequence wrap is forbidden; failure to persist a pre-exhaustion rotation stops emission,
never modularly resets the sequence.

Gateway Runtime owns only mesh membership, bounded signed state, ownership projection, DNS, and
its local journal. It does not bootstrap Vault, own lifecycle leases/checkpoints/outboxes, mutate
target Vault KV, or proxy generic object-store operations. Those authorities and the pure
operation-indexed capability design are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

DNS mutation is credential-gated as well as ownership-gated: the interpreter may construct a Route
53 effect only from an authorized plan containing current ownership evidence and an observed,
usable credential generation. Missing or unobservable credentials refuse the effect before any
native Route 53 request starts.

Kubernetes `/healthz` and `/readyz` probes are constant-time projections over lifecycle flags.
Kubelet-facing readiness is one pure projection over drain phase, current emitter authority, and
worker-started state. The rollback topology latches a validated continuity startup. The target
topology instead requires the current identity-bound journal lock, matching Kubernetes Lease
witness, and completed recovery; Lease loss may move `Ready` back to `Starting`, while drain is
absorbing. No probe handler performs backend I/O and no environment hook bypasses authority. An
unconditional serve-start readiness write is a superseded defect. Restart/OOM/high-water stability is a separate, time-windowed external
observation; a point-in-time `StatefulSet Ready=True` result is not stability proof.

This doctrine covers the Haskell distributed gateway daemon only. The Kubernetes Gateway API
public-edge controller target is owned separately by
[Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md).

Every gateway daemon HTTP path string is a projection of one compiled route registry
(`Prodbox.Gateway.Routes`, Sprint `2.34`): the closed `GatewayRoute` ADT (`Enum`/`Bounded`) is the
single place any path exists, `routeClass` distinguishes liveness/readiness/diagnostic/RPC, the
daemon dispatcher is a total `case` over the registry (a registered route with no handler is a
`-Werror` compile error), and the gateway client and chart kubelet-probe paths are projections of
the same `routePattern`. A kubelet probe cannot be built from a diagnostic or RPC route (the
`kubeletProbeRoute` smart constructor). The constant-time `/healthz` and `/readyz` endpoints have
existed since Sprint `2.10`. Sprint
`2.31` landed the bounded state, transport, remote Model-B continuity adapter, memory-consumer, and
credential-gated DNS implementation on top of Sprint `1.60`'s runtime-memory plan. Sprint `3.25` landed the
separate chart binding to those endpoints and forbids `/v1/state` as a kubelet probe. Sprint `5.16`
landed the external restart/OOM/high-water stability classifier, concurrency-safe shared recorder,
structured continuous monitor, and final `gateway-pods` gate. Status for the local-journal actor
cutover, legacy route removal, and deployment qualification is owned by the Development Plan, not
this doctrine.

---

## 1. Non-Negotiable Requirements

This design assumes:

1. No centralized election coordinator (no DynamoDB lease or external owner oracle). The local
   encrypted emitter journal is mandatory write-ahead persistence for signed continuity state; it
   does not choose the gateway owner.
2. All nodes are fully trusted mesh peers identified by Orders membership and per-node event
   keys; peer trust material remains part of the gateway config and chart contract.
3. A typed global Orders document exists (Dhall-authored, CBOR-serialized on the wire — see
   [pulsar_messaging_doctrine.md](./pulsar_messaging_doctrine.md)), with monotonic UTC version
   timestamp.
4. Nodes promote newer validated Orders promptly, via the restart-based boot-field
   reload path (§7.5), not by mutating Orders version in process.
5. Every node has a stable peer endpoint in Orders for mesh communication.
6. Only gateway owner updates the canonical public DNS record `test.resolvefintech.com`.
7. The convergent, bounded semantic replica state is the runtime decision source of truth. Peers
   exchange bounded cursor deltas/snapshots, while mandatory emitter continuity survives total peer
   restart in each node's retained identity-bound journal; peer recovery never substitutes for that
   durable anchor.

---

## 2. Planning Ownership

This document owns gateway architecture doctrine only.

Clean-room sequencing, completion status, remaining work, and legacy-path
removal for gateway delivery are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

This document defines the gateway architecture and formal protocol contract.
Current module-to-model correspondence, runtime compression points, and verification-boundary notes
are owned by [TLA+ Modelling Assumptions](./tla_modelling_assumptions.md).

Canonical repository facts referenced by this doctrine:

1. `src/Prodbox/Gateway.hs` owns `prodbox gateway start|status|config-gen`.
2. `src/Prodbox/Gateway/Daemon.hs` owns the running gateway daemon runtime.
3. Verification artifacts include `test/unit/Main.hs`, native named validation flows behind
   `prodbox test integration gateway-daemon` and `prodbox test integration gateway-pods`, and
   `documents/engineering/tla/gateway_orders_rule.tla`.

---

## 3. Architecture Overview

## 3.1 Orders Plane (Control Intent)

`Orders` is the declarative configuration object (authored in Dhall, CBOR-serialized on the wire —
see [pulsar_messaging_doctrine.md](./pulsar_messaging_doctrine.md)):

- `orders_version_utc` (int64, strictly increasing)
- `orders_hash`
- `nodes[]` (node_id, stable peer endpoint fields, rank)
- `gateway_rule` (schema-constrained rule)
- `rule_parameters` (timeouts, windows, jitter, etc.)

Nodes validate signature + schema + monotonic timestamp before promotion.
They also reject raw Orders above the configured byte limit, more than `max_members`, duplicate
members/ranks, and any member field above its byte bound before allocating runtime maps or
checkpoint/snapshot projections. The validated membership bound is an input to the
`RuntimeMemoryPlan`.

## 3.2 Event Plane (Source of Truth)

Peers exchange signed, hash-identified assertions:

- Canonical signed CBOR bytes determine the assertion digest; the digest is derived by the receiver,
  not accepted as a caller-selected wire field.
- Assertions are ordered by Orders anchor, emitter, fixed-width epoch, and fixed-width sequence.
  Each assertion carries the previous digest for that emitter only; concurrent emitters never
  pretend to share one global hash chain.
- A signed per-emitter semantic snapshot carries one compaction cursor plus the original signed
  heartbeat and ownership evidence present at that cursor. A repair frame combines that snapshot
  with a contiguous bounded replay suffix.
- Every assertion is HMAC-signed by its emitter. Heartbeat assertions carry the heartbeat timestamp;
  ownership and epoch-invalidation assertions do not invent an unrelated event timestamp.

Assertion classes:

- `HeartbeatAssertion timestamp`
- `OwnershipAssertion OwnershipClaim`
- `OwnershipAssertion OwnershipYield`
- `EpochRotationAssertion`
- `OrdersMigrationAssertion scope` (exact prior cursor and authenticated prior Orders digest)

The accepted runtime projection is finite:

| Semantic component | Retention rule |
|---|---|
| Heartbeat view | Latest valid heartbeat per Orders member, with member count bounded by validated Orders |
| Ownership view | Latest valid claim/yield evidence per bounded Orders member for the active Orders version, plus at most one bounded promotion slot; older-version evidence is evicted after checkpointed promotion |
| Orders view | Active version plus at most one highest-observed/staged version needed by the restart gate |
| Replay window | Bounded original signed assertions per emitter; the default capacity is eight |
| Emitter continuity (hot) | Current fixed-width epoch/sequence and previous-emitter hash per Orders member; no historical epoch list |
| Durable continuity anchor | One encrypted identity-bound retained journal per daemon: stable identity/admission/incarnation, active/prior Orders digests, immutable trusted floor, committed cursor, at most one staged assertion, a bounded contiguous retained suffix, and bounded known-peer ack/checkpoint projection |
| Diagnostic history | Exactly 64 recent assertion digests process-wide; no logical audit history is retained by the gateway |

Replication is anti-entropy gossip over the stable peer endpoints carried in Orders. Each accepted
assertion must advance a member/version/sequence key or be rejected as stale or duplicate. The
semantic fold is deterministic and idempotent, so replaying a bounded delta does not grow state.
Logical audit history, if a future requirement introduces it, belongs in a separately budgeted
durable sink; it is not part of the current gateway runtime. The bounded replay and 64-digest
diagnostic ring are operational repair/diagnostic structures, not an audit trail. Their boundedness
never permits the mandatory local continuity record to be omitted, inferred from peers alone, or
acknowledged before its retained write succeeds.

## 3.3 DNS Plane

1. One canonical public record exists: `test.resolvefintech.com`.
2. Mesh peers discover each other through the stable peer endpoint data carried in Orders and
   rendered by `charts/gateway/`; that peer mesh is not a second public-host doctrine.
3. Only elected gateway owner updates the canonical public record.

---

## 4. Gateway Rule Model

## 4.1 Safe-by-Construction Rule Schema

Only rule families with machine-checkable invariants are allowed.
Initial allowed family:

- `RankedFailoverRule` with deterministic total order over nodes.

Inputs:

- ordered node ranks from Orders
- heartbeat freshness from the bounded semantic heartbeat view
- rule timeouts

Output:

- exactly one `intended_gateway_owner` for a given state snapshot

Tie-break is fixed: `(rank, node_id)` lexicographic.

## 4.2 Required Failsafe

Rule schema must enforce:

- `isolation_timeout_seconds` is defined as `heartbeat_timeout_seconds`.
- If a node has no fresh heartbeat from peers for `isolation_timeout_seconds`, it must become self-candidate.

This satisfies the “all others down” takeover requirement.

---

## 5. Safety Boundary (Important)

In a fully asynchronous system, with partitions and no consensus primitive, you cannot guarantee both:

1. absolute no-split-brain leadership safety, and
2. always-available autonomous failover.

This is a fundamental distributed systems limit.

Therefore the design contract is:

1. `NoTugOfWar` is proven for the modeled assumptions (bounded skew/delay or equivalent failure-detector assumptions in TLA+).
2. Under severe partition uncertainty, the implementation makes the explicit choice
   **availability-first (best-effort)**: an isolated node self-elects as a failsafe and keeps serving,
   accepting a *bounded, self-healing* split-brain rather than failing closed. The rejected alternative is
   safety-first / fail-closed (refuse to act until sole ownership is proven) — not chosen, because the
   gateway's purpose is to keep traffic reaching a live owner.

The schema can forbid ambiguous rule forms, but cannot bypass impossibility results.

## 5.1 Topology and Fault Model

The two substrates differ in physical failure independence, not in the logical protocol:

- **Home (single physical host)** — the chart runs three logical ranked peers (`node-a`, `node-b`,
  and `node-c`) as separate stable StatefulSet identities on one physical host. Logical peer loss, one-way transport
  failure, and network-policy partitions remain meaningful protocol scenarios. A physical host
  failure is shared fate, however: all three peers and the cluster they gate disappear together, so
  the home topology cannot demonstrate independent-host failover.
- **AWS / future multi-host** — genuine partition tolerance (and the
  `NoTugOfWar` / `UniqueOwner` safety properties the TLA+ model verifies)
  becomes load-bearing only when the mesh spans more than one host that can
  partition independently. That is the AWS substrate and any future
  multi-host topology, not the home single-host degenerate case.

Doctrine and the TLA+ model are written for independent logical peers. The home substrate is the
shared-physical-fate instance of that protocol, while AWS or a future multi-host topology exercises
the additional host-failure independence.

---

## 6. Rejoin + Eventual Consistency

When a silent node returns:

1. Its single emitter actor takes the substrate-appropriate volume fence and OS lock, loads and
   increments the durable incarnation, and reconciles the journal/admission-marker transaction.
   On first admission, authoritative marker absence permits the exclusively locked journal to be
   initialized and fsynced before the marker is conditionally written and read back. A crash after
   the journal fsync but before marker read-back resumes that authenticated journal and retries the
   marker operation. Marker presence with a missing journal, or any corrupt or mismatched journal,
   refuses emission and requires receipt-committed retirement plus a new identity. Only after that
   reconciliation succeeds does the mount acquire the matching Kubernetes Lease and expose the
   actor.
2. It restores the authenticated checkpoint floor, complete contiguous retained committed suffix,
   previous anchor, incarnation, peer-ack projection, and any exact signed in-flight record. Every
   retained signed phase rewinds to the durable-stage boundary, clears its volatile publication
   witness, and re-fsyncs and republishes the same canonical bytes before commit and the final
   projection fsync. This includes a migrated projection that crashed before publication. Only
   committed suffix records still waiting on at least one current peer are otherwise republished.
3. It reconnects via the stable peer endpoints carried in Orders and advertises its bounded receive
   cursor vector.
4. A peer sends a contiguous bounded delta after that vector. If a component lies behind the replay
   frontier, the peer sends the authenticated per-emitter checkpoint floor plus its bounded
   contiguous suffix, then resumes delta exchange.
5. It validates Orders version, emitter identity, signature, sequence/cursor monotonicity, schema,
   and frame bounds before applying anything.
6. It folds peer evidence into bounded hot state only when verification succeeds. Peer evidence does
   not mutate the local emitter journal; every later local assertion still follows the actor-owned
   `stage -> fsync -> publish -> commit -> fsync` protocol.
7. It promotes latest Orders by UTC version through the restart boundary.
8. It recomputes gateway candidacy and either:
   - yields immediately, or
   - starts/continues gateway ownership actions if selected.

This provides deterministic convergence without using peers as continuity authority. If every peer
restarts together, each recovers its own safe emitter anchor and any unacknowledged ownership
transition, then resumes without sequence reset or wrap. Heartbeat requests may be coalesced before
admission; committed canonical bytes are retained until an authenticated checkpoint compacts their
prefix. Peer acknowledgement controls republish selection, not chain deletion.

---

## 7. P2P Protocol Requirements

## 7.1 Transport

- Peer transport is a bounded HTTP cursor/delta/repair protocol on the configured peer-events port:
  `GET /v1/peer/cursor`, `POST /v1/peer/delta`, and `POST /v1/peer/repair`. `GET /v1/state` is the
  separate operator-facing observability surface.
- Certificate, key, CA, and socket fields remain part of the gateway
  config and chart trust-material contract for the peer mesh. The daemon
  validates the retained certificate, key, and CA files at startup and
  binds the REST plus peer-events listeners on the configured local
  Orders hosts before the signed peer mesh begins.
- Node identity is bound to the Orders `node_id` mapping: the receiver
  validates each event's HMAC signature against the per-node key in
  `daemonEventKeys`, refuses unknown emitters, and ignores events whose
  emitter id is outside the Orders node set.

### 7.1.1 Per-Connection Isolation Contract

Both listeners — the peer cursor/delta/repair listener and the operator-facing REST surface
(`/v1/state` and the health/metrics endpoints) — handle
each inbound connection in isolation so
a slow, stuck, or malformed peer cannot wedge the daemon:

- Each accepted connection is served by a tracked `async` child, retained in a bounded active list,
  polled to completion, and cancelled/reaped during drain. No raw `forkIO` child can escape the
  listener supervisor.
- Each connection read is bounded by a read timeout. A peer that opens a socket
  and then stalls mid-request is timed out and dropped rather than holding a
  handler thread open indefinitely; the accept loop keeps serving other peers.
- Peer `Content-Length` is rejected during header preflight before body accumulation. Admission is
  bounded after decode by assertions per frame and aggregate encoded bytes. The peer-listener cap
  and the process-wide `envFramePermits` queue shared by both listeners prevent valid concurrent
  connections from multiplying memory beyond the transport reserve.
- A failed, timed-out, or malformed connection mutates no daemon state — it is
  dropped after the existing schema / sequence / HMAC validation rejects it
  (see §7.3), and the listener returns to accepting.

Sprint `2.25` landed the bounded read timeout; Sprint `2.31` added bounded active children,
pre-allocation HTTP framing, decoded-frame limits, and the shared process-wide permit. The socket
read remains bounded by `liveConnectionReadTimeoutSeconds`; a timeout is a benign connection-local
drop rather than a `Fatal` worker error, including during `Draining`.

## 7.2 Bounded Delta Replication

- Each daemon first fetches the receiver's bounded cursor vector and then sends at most one bounded
  delta frame. `POST /v1/peer/delta` carries the active Orders anchor, exact base cursor, and a
  bounded assertion batch keyed by emitter epoch/sequence; the response carries the resulting
  cursor vector.
- When delta selection reports that one emitter is behind the retained replay frontier, the sender
  builds `POST /v1/peer/repair` from that emitter's authenticated compaction checkpoint: its exact
  floor cursor and projection plus a contiguous bounded suffix. After repair it
  retries delta selection once. Repair size is bounded by the same assertion-count and frame-byte
  limits, not by daemon uptime.
- Acceptance is idempotent: the receiver's pure fold advances only monotonic semantic keys and
  cursors. Repeated frames are acknowledged without changing retained cardinality.
- Local publication is persistence-first and single-owner: prepare and sign the next assertion,
  stage its exact bytes and next anchor in the encrypted local journal, `fsync`, publish, promote
  the stage into the bounded retained suffix with its exact bytes/previous anchor and `fsync` again.
  Peer acknowledgments update the durable ack projection and republish selection; only checkpoint
  installation may clear a committed prefix. A journal conflict, unavailable observation,
  or durability failure emits nothing. No independent continuity loop may stage or commit another
  transition, and the heartbeat path does not call a remote Model-B authority.
- Restart/overflow never resets a sequence in place. The emitter either resumes the recovered
  current epoch at `sequence + 1`, or conditionally persists a signed epoch-invalidation assertion
  to a fresh epoch before emitting. Frames from an invalidated epoch are rejected even if delayed past
  compaction.
- The receiver updates its view of every other node's last heartbeat from
  the newest accepted inbound heartbeat rather than from the local heartbeat loop
  alone, closing the documented gap between the runtime and the TLA+
  model's peer-communication assumptions.
- The receiver also tracks per-peer health and exposes it on `/v1/state` as
  two **separate** top-level fields — `peer_inbound_health` and
  `peer_outbound_health` — so a one-directional partition is observable rather
  than collapsed into a single value. Inbound and outbound health have distinct
  meaning and must not be conflated:
  - **Inbound health** (`peer_inbound_health.<peer>.last_inbound_event_age_seconds`)
    — age of the last *inbound* event from that peer. It is written only when
    this daemon actually receives and accepts a signed assertion from the peer, and
    it is the freshness signal that feeds heartbeat and isolation judgements
    (§4.2).
  - **Outbound health** (`peer_outbound_health.<peer>.{connected,last_error}`)
    — whether this daemon's last *push to* that peer succeeded (connect state,
    last dial error). It reflects our own delivery attempts and says nothing
    about whether the peer is producing events.
  - `markPeerOk` runs on a successful outbound push and writes **only** the
    outbound fields. It must not stamp the inbound-event timestamp: a one-way
    "we could reach the peer's socket" success is not evidence that the peer is
    alive and emitting, and treating it as inbound freshness would mask a peer
    that accepts connections but has stopped producing events, defeating the
    isolation failsafe. Sprint 2.25 split these into separate fields so the
    outbound-push callback can no longer advance inbound freshness; the prior
    conflated `peer_transport` field is retired.

### 7.2.1 At-Least-Once Correspondence

`src/Prodbox/Daemon/Events.hs` is the canonical at-least-once helper for durable daemon event
consumers that need `processed_at` tracking, idempotent handlers, and replay from a persistent
store. The gateway peer mesh is not a durable work queue: it uses monotonic cursor acknowledgement
and an idempotent semantic fold. Duplicate delivery is permitted, but duplicate retention is not;
the bounded replay window exists only to bridge ordinary cursor lag, while semantic snapshots
repair lag beyond that window.

Future daemon consumers that pull work from a durable queue or table use `Prodbox.Daemon.Events`;
the gateway shares the idempotency and ordering discipline without retaining an unbounded work
history.

The former append-only commit-log and complete-list retransmission path has no supported
compatibility representation. `GatewayState`, signed replay maps, per-emitter compaction
checkpoints, and cursor/delta/repair frames are the only peer-state path. The
[legacy deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md) records that
removal as history.

## 7.3 Corruption Resistance

- Per-event schema validation.
- Monotonic member/version/epoch/sequence, per-emitter previous-hash, and cursor-integrity checks;
  there is no global hash chain across concurrent emitters, no in-place sequence reset, and no
  counter wrap.
- Retained continuity checkpoint authentication, Orders/member/bound validation, and conditional
  expected-prior-anchor writes; `Missing`, `Corrupt`, and `Unreachable` refuse publication.
- HMAC signature verification (rejected pushes never mutate state).
- Reject-on-invalid, never partially apply.

## 7.4 Operator Time-Base Discipline

- The supported-host gate (`prodbox host info`) reports the host's NTP
  synchronization disposition derived from `timedatectl` and fails fast
  when the host is reachable but reports the system clock as
  unsynchronized.  Every freshness judgement and claim/yield ordering check
  in the daemon compares wall-clock UTC stamps across nodes, so a drifting
  operator clock breaks the model's bounded-delay assumption.
- The gateway daemon refuses inbound events whose timestamps lie beyond
  the configured `max_clock_skew_seconds` bound (default 10 seconds, range
  `[0.1, 600]`).  Rejected events appear in the push response's
  `rejected` list with the offending skew.
- The daemon records the maximum observed inter-node skew on
  `/v1/state` as `max_clock_skew_seconds_observed` so operators can
  detect drift before it crosses the configured bound.

## 7.5 Orders Promotion (Restart-Based, Journal-Migrated)

Orders is a `BootConfig` field (cluster topology / ranked-node membership),
not a live-reloadable knob. Promotion of a newer Orders document is therefore
**restart-based**, following the file-watch reload contract in
[config_doctrine.md §8 step 4](./config_doctrine.md#8-boot-vs-live-split-and-the-restart-contract):
when the watcher observes a changed Orders mount, the daemon logs
`config_reload_boot_change_detected`, drains within the bounded deadline, and
exits `ExitSuccess`; the kubelet restarts the Pod, which decodes the new Orders
fresh at startup and binds its rank, peer set, and timing from it. The new process
must not merely relabel the retained journal. If the authenticated journal Orders
digest differs, it preserves the committed cursor and suffix, adopts a fresh
incarnation/current peer set, clears old-Orders acknowledgements and in-flight work,
and performs a separately-ticketed authenticated Orders-scope invalidation bound to
the exact prior digest and cursor. That transition advances to `(epoch + 1, 0)` even
when the old sequence is below exhaustion, rejects epoch overflow, and must finish
`stage -> fsync -> publish -> commit -> fsync` before readiness or any new-Orders
assertion. Normal epoch rotation remains legal only at sequence exhaustion.

The version-3 durable projection preserves that authenticated prior-Orders digest through ordinary
commits, acknowledgement fsyncs, checkpoint compaction, incarnation rebases, and encode/decode.
Recovery re-arms the exact State admission from the retained digest before replay. A crash after the
projection migrates but before publication, or a refusal at the final projection fsync, therefore
rewinds to the durable-stage boundary and republishes the same signed migration bytes; conflicting
pending, in-flight, suffix, latest, or checkpoint evidence fails closed instead of relabelling the
journal.

- Each peer push includes the sender's current `orders_version_utc`, and the
  receiver returns `409 Conflict` when the sender's view is older than the
  receiver's. This prevents a stale peer from pushing events that predate the
  receiver's (startup-bound) Orders version.
- The running process tracks the highest observed Orders version on `/v1/state` as
  `latest_observed_orders_version_utc`. When the peer view advances past the
  local (startup-bound) Orders, the daemon **refuses to claim ownership** until
  it is restarted against the newer Orders — the refuse-to-reclaim-while-behind
  gate. The only way to clear the gate is the restart, journal migration, and
  completed recovery path above; a daemon rebooting against stale Orders or an
  incomplete invalidation cannot reclaim DNS write authority.
- There is no live-reload `orders_promoted` semantic event. The
  `eventTypeOrdersPromoted` / `orders_promoted` event class and its threading
  remain removed. The journal-migration invalidation is a distinct authenticated
  continuity transition executed only during the new mount's recovery boundary;
  it is not an ordinary peer-supplied promotion event.

---

## 8. TLA+ Scope

The finite TLA+ safety model covers the representative two-node protocol's bounded types, complete
journal phase shape, exact admission identity and expiry, stale-completion fencing, monotone durable
incarnation, OS-lock/Lease binding, Orders-scoped semantics, durable bounded pending/ack/checkpoint
slots, and the complete DNS authority gate. It does not claim liveness, real-time clock behavior, or
the production three-member cardinality. This actor-local refinement deliberately holds
`activeOrders` fixed; the concrete authenticated Orders migration and migrated-projection re-arm are
native-test obligations, composed with the earlier Orders/ranked-owner/partition proof axis. The
exact 16-invariant catalog, action correspondence, canonical exhaustive-run counts, and proof boundary are owned by
[TLA+ Modelling Assumptions](./tla_modelling_assumptions.md).

Model files:

- `documents/engineering/tla/gateway_orders_rule.tla`
- `documents/engineering/tla/gateway_orders_rule.cfg`

Execution requirement:

- TLA+ checks must run via Docker using `maxdiefenbach/tlaplus`.
- `src/Prodbox/Tla.hs` owns the public `prodbox dev tla-check` entrypoint.
- Use the CLI command `prodbox dev tla-check`.
- The command runs a self-deleting container (`docker run --rm ...`) and writes the latest result to `documents/engineering/tla/tlc_last_run.txt`.

For modelling assumptions, variable correspondence, known divergences, and verification status, see [TLA+ Modelling Assumptions](./tla_modelling_assumptions.md).

---

## 9. GatewayClaim / GatewayYield Event Lifecycle

Ownership transitions are transported as typed signed assertions and folded into the bounded
ownership view emitted by the running daemon:

| Event | Trigger | Payload |
|-------|---------|---------|
| `claim` | This node becomes elected gateway owner | `{"claiming_node_id": str, "previous_owner": str \| None}` |
| `yield` | This node loses gateway ownership | `{"yielding_node_id": str, "new_owner": str \| None}` |

**Ordering guarantee**: A `yield` from the old owner is emitted before a `claim` from the new owner
when both transitions land in the same recomputation cycle. The semantic fold retains the newest
valid evidence per node/version and enough bounded transition evidence to enforce
yield-before-reclaim. It does not require every historical heartbeat or ownership transition to
remain resident for the process lifetime.

---

## 10. DNS Write Gating

Only the elected gateway owner with observed usable credentials and durable continuity writes the
primary DNS A record. Four conditions must be satisfied in the runtime, materialising the modelled `CanWriteDns`
predicate plus the interpreter's credential capability:

1. **Ownership check**: `gateway_owner == self.node_id`
2. **Claim check**: the most recent claim/yield event from `self.node_id`
   in the bounded ownership view is a `claim`, not a `yield`.
3. **Credential check**: the current DNS credential observation is `CredentialsReady generation`;
   absent, stale, or unobservable credentials produce a refusal value.
4. **Continuity check**: the current authority observation is `ContinuityReady checkpoint`, and its
   emitter anchor matches the durably persisted anchor that carries the active claim; missing,
   corrupt, stale, or unobservable continuity refuses the effect.

The pure DNS planner returns either a structured refusal or a `DnsWriteAuthorized` value carrying
the owner evidence, committed journal transition, emitter incarnation, deterministic credential
generation, and continuity-anchor fence. The registered account/zone/FQDN/type/ownership-epoch
coordinate exists only in `CapabilityRef 'GatewayDnsReconcileReadBack`; `GatewayDnsIntent` carries
only desired IP/TTL plus the opaque signed `CommittedIntentRef 'GatewayDnsMutation`. Admission,
domain pre-observation, conditional change, and authoritative read-back execute through that same
reference and its bounded native Route 53 client/session lane. There is no separately supplied
endpoint or coordinate, capacity-one process lease, AWS subprocess, ambient profile, or credential
fallback on the target path.

The role-scoped session manager projects only the committed Gateway-DNS credential generation. A
generation change is a typed boot-reload decision that drains and restarts the daemon. Missing or
unobservable ownership, journal, receipt, credential, or exact-record evidence therefore refuses
before the native adapter receives an effect.

Because the bounded semantic ownership view is replicated through anti-entropy gossip (see §7), a
stale owner that has yielded cannot reclaim DNS write authority without first observing a fresh
claim from itself superseding its own yield.

The daemon emits a signed `claim` assertion on the non-owner-to-owner transition and a signed
`yield` assertion on the owner-to-non-owner transition, so `ClaimPrecedesWrite` and
`YieldPrecedesReclaim` are properties of the semantic fold rather than of an indefinitely retained
list.

Current runtime correspondence and any compressed operational status fields are documented in
[TLA+ Modelling Assumptions](./tla_modelling_assumptions.md).

### DnsWriteGate Configuration

`DnsWriteGate` carries:

- `zone_id`
- `fqdn`
- `ttl`
- `aws_region`

When `dns_write_gate` is `None`, the daemon leaves Route 53 writes disabled.

### Daemon Config Shape

The gateway config generator emits a structured daemon config with top-level `schemaVersion`,
`boot`, and `live` records. Boot-only fields include node identity, TLS material, Orders path,
event keys, and `dns_write_gate`; live fields include log level, heartbeat/reconnect/sync
intervals, clock-skew bound, and drain deadline. The parser still accepts the earlier flat JSON
shape as compatibility input, but structured config schema mismatches fail as
`config_schema_mismatch` and preserve the running live config during reload.

The structured `schemaVersion` / `boot` / `live` template is the implemented gateway-daemon
runtime shape. Config-schema hygiene remains governed by the shared config discipline rather
than by a separate gateway-local defaults file.

### Tier-0 Non-Secret Config Delivery (Cluster Mount Contract)

The daemon's non-secret config source is the Tier-0 `prodbox.dhall` (binary-owned, project-local
parameters + context + witness, never secrets) defined in
[config_doctrine.md §0](./config_doctrine.md#0-three-tier-config-model). This doctrine owns the
in-cluster delivery contract for that file: it is mounted into the gateway Pod through the existing
per-node `gateway-config-<nodeId>` ConfigMap at `/etc/gateway/config`. The mount is a
**directory** mount, not a file mount, so kubelet's atomic `..data` symlink swap on ConfigMap
update fires the daemon's fsnotify watcher and drives the file-watch reload path (§7.5 for the
boot-field restart contract; the live-field swap is governed by
[config_doctrine.md §7](./config_doctrine.md#7-file-watch-reload-trigger)).

The production chart plan places both `config.dhall` and `prodbox.dhall` in that ConfigMap. It
renders the latter from `defaultDaemonProjectConfig`, preserving the `Daemon` frame and changing
only `context.cluster_id`: the home-local value is projected from the established binary-sibling
Tier-0 floor, and the AWS value is `awsEksCanonicalClusterName`. The daemon's Tier-0 loader prefers
this mounted sibling to its image-baked fallback. Target-secret routes use that loaded cluster ID
to attest the request coordinate, so selecting an AWS port-forward with a home identity (or the
reverse) is refused before Vault access.

This realizes hostbootstrap's binary-owns-its-config + ConfigMap-overwrite (context-init) pattern.
The built container ships **no** committed or `COPY`-ed default `prodbox.dhall`: the image build,
after installing the binary, **runs the binary** (`prodbox config generate`) to write a
binary-sibling `prodbox.dhall` that serves ephemeral in-container CLI commands (Sprint `1.49`). The
long-running cluster daemon is configured by the rendered `gateway-config-<nodeId>` ConfigMap mount
(unchanged) — independent of that build-time binary-sibling default. See
[config_doctrine.md §0](./config_doctrine.md#0-three-tier-config-model) and
[§3](./config_doctrine.md#3-canonical-paths) for the canonical tier model and the binary-sibling
resolution; it is not duplicated here.

Secrets are never carried in the Tier-0 mount. The daemon resolves every credential through
`SecretRef.Vault` pointers (Tier-2 operational secrets) using its own Vault Kubernetes-auth
identity at startup, as described throughout §10 and §12.2.

### Structured Logging

The gateway daemon and public workload daemon entrypoints emit structured JSON log lines to
stderr through `src/Prodbox/Gateway/Logging.hs`, backed by `co-log`. Log sites pass typed fields
through `field`; daemon-path lint rejects inline log-object construction in log calls.

Gateway log filtering reads `envLiveConfig` at each log site. The configured log level is seeded
from the Dhall `--config` file at startup and subsequent file-watch reloads (per
[config_doctrine.md §7](./config_doctrine.md#7-file-watch-reload-trigger)) update the live
log threshold for later log calls without restart. The `prodbox-daemon-lifecycle` stanza
verifies the stderr JSON envelope and the file-watch-driven log-level path.

### Route53DnsWriteClient

The target home writer resolves `CapabilityRef 'GatewayDnsReconcileReadBack` for one registered
account/zone/FQDN/type/ownership-epoch coordinate. The program carries only the desired IP/TTL plus
current claim, emitter-incarnation, continuity, and Gateway-DNS credential-generation evidence;
the coordinate cannot be supplied again or changed after admission. Its adapter observes the exact
record, conditionally applies the change through the dedicated Gateway-DNS session, and reads back
the authoritative record under the same request deadline. Desired absence uses the same reference.
The EKS Gateway has no DNS-mutation capability; the AWS A record belongs to a Lifecycle Authority
provider intent.

**Historical pre-cutover implementation.** The current daemon still invokes `curl` for public-IP
discovery and `aws route53 change-resource-record-sets` for direct UPSERT, with the shared
`secret/gateway/gateway/aws` credential seeded by `vault reconcile`. Those children are bounded by
the current runtime-memory plan, but they have no registered record epoch/read-back/tombstone and
are not the target writer. Sprints `4.50`/`7.33` remove the direct subprocess paths, shared Vault
coordinate, and EKS gateway fallback after exact-record cutover.

---

## 11. REST API

The target Gateway Runtime surface is limited to the bounded peer protocol, read-only gateway
state, constant-time health/readiness, and metrics described below. Bootstrap, lifecycle,
object-store, federation-custody, and target-secret operations belong to their separately deployed
services. The route descriptions explicitly marked historical in this section record the current
implementation that must be removed during the plan-owned epoch cutover; they confer no target
authority on Gateway Runtime.

### Peer cursor, delta, and repair routes

`GET /v1/peer/cursor`, `POST /v1/peer/delta`, and `POST /v1/peer/repair` form the bounded peer
protocol over the configured peer-events port. Each response reports an explicit accept/reject
disposition and the receiver's bounded cursor vector when available.

### `GET /v1/state`

Returns current daemon state:

```json
{
    "node_id": "node-a",
    "gateway_owner": "node-a",
    "previous_owner": null,
    "has_active_claim": true,
    "can_write_dns": true,
    "node_disposition": "owner",
    "peer_dispositions": {"node-b": "yielded"},
    "mesh_peers": ["node-b", "node-c"],
    "semantic_member_count": 3,
    "signed_replay_assertion_count": 5,
    "retained_assertion_count": 7,
    "retained_assertion_capacity": 30,
    "recent_assertion_hashes": ["abc123", "def456"],
    "peer_receive_cursors": {
        "node-b": {
            "node-a": {"epoch": 4, "sequence": 1042, "digest": "a1b2c3"},
            "node-b": {"epoch": 2, "sequence": 995, "digest": "d4e5f6"},
            "node-c": {"epoch": 1, "sequence": 88, "digest": "778899"}
        }
    },
    "emitter_journal": {
        "status": "ready",
        "epoch": 4,
        "sequence": 1042,
        "digest": "a1b2c3"
    },
    "last_public_ip_observed": "203.0.113.10",
    "last_dns_write_ip": "203.0.113.10",
    "last_dns_write_at_utc": "2026-04-06T12:00:00Z",
    "heartbeat_age_seconds": {
        "node-a": 0.2,
        "node-b": 1.3
    },
    "peer_inbound_health": {
        "node-b": {
            "last_inbound_event_age_seconds": 0.7
        }
    },
    "peer_outbound_health": {
        "node-b": {
            "connected": true,
            "last_error": null
        }
    },
    "max_clock_skew_seconds_observed": 0.4,
    "max_clock_skew_seconds_bound": 10.0,
    "orders_version_utc": 1700000000,
    "latest_observed_orders_version_utc": 1700000000,
    "dns_write_gate": {
        "zone_id": "Z1234567890",
        "fqdn": "test.resolvefintech.com",
        "ttl": 60,
        "aws_region": "us-east-1"
    }
}
```

Used by integration tests for observability and by `prodbox gateway status` CLI.

`retained_assertion_count` is bounded by `retained_assertion_capacity`; it is not total assertions
since process start. `semantic_member_count`, signed replay count, recent hashes, and the
peer-by-emitter cursor vectors are bounded by validated Orders and gateway bounds. The journal
projection reports the already-observed local committed anchor coordinates and digest, but never a
signature, key, staged payload, or journal read performed during rendering. The state response
never scans an uptime-proportional history. Fields from the former append-only representation are
absent.

The `/v1/state` observability endpoint is an operator-facing HTTP surface on the in-pod REST
port. It is separate from the peer-to-peer cursor/delta/repair transport used for gateway mesh
communication. The REST handler consumes the inbound HTTP request before closing the socket so the
operator-facing response contract stays intact when queried through the daemon NodePort. It is not
a Kubernetes liveness/readiness probe and is not polled at probe cadence.

### Removed Secret-Derivation Endpoints

Sprint `3.19` removed the gateway daemon's former `/v1/secret/derive` and
`/v1/secret/ensure-namespace` endpoints. Secrets are not derived by the gateway daemon anymore:
each secret is a Vault KV / PKI / Transit object, and each in-cluster consumer authenticates to
Vault with its Kubernetes service account. The host-side gateway client covers status, daemon
observability, and the Vault-backed federation read endpoints below.

Supported chart pre-install Jobs and host/admin helpers read/write Vault objects directly through
their owned roles/helpers. The deleted RPC family's history belongs only in
[the cleanup ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md), not in a current-path
payload example.

### Historical Federation Read Endpoints (Legacy Cutover Surface)

The following Sprint `2.26` gateway-mediated routes are an implementation record, not the target
authority boundary:

- `GET /v1/federation/children` logs in to Vault through the daemon's configured Kubernetes-auth
  block, reads `secret/data/clusters/index`, fetches each child metadata object, and returns
  metadata-only downstream inventory. It never returns the transit-seal token.
- `GET /v1/federation/children/<child>/bootstrap` logs in through the same Vault path and returns
  the parent-custodied child bootstrap credential from
  `secret/data/clusters/<child>/bootstrap`.

Both endpoints fail closed when Vault auth, Vault reachability, or KV decoding fails. They do not
read child inventory from repository Dhall, Kubernetes Secrets, or gateway-local files.

### Historical Operator-Write Endpoint (`POST /v1/secret/<logical>`, Legacy Cutover Surface)

The following Sprint `1.44` route is an implementation record, not a target Gateway Runtime
capability. Target writes use the allowlisted, generation-checked Target Secret Agent through one
operation-indexed `CapabilityRef`; observation, admission, CAS, and read-back cannot be rebound to
a separately supplied endpoint. Historically the host CLI (a real operator, or the
test harness simulating one) persists the two host-minted operator secrets through the in-cluster
daemon over the loopback-restricted NodePort instead of a host root-token direct Vault write:

- `POST /v1/secret/acme/eab` — the ZeroSSL external-account-binding material.
- `POST /v1/secret/gateway/gateway/aws` — the minted operational `aws.*` credential.

The logical path is a fixed two-entry allowlist (`allowedOperatorSecretPaths`); any other
`/v1/secret/*` path is a `404`, and a non-`POST` method on an allowlisted path is a `405`. The
endpoint never echoes the written secret back — the secrets it owns are read in-cluster via Vault
Kubernetes auth, never returned over REST.

Authentication is by an **operator-injected Kubernetes JWT** carried in the
`X-Prodbox-Operator-Jwt` header (operator decision 2026-06-19). The daemon exchanges that JWT for
a short-lived Vault token under the dedicated, narrowly-scoped `prodbox-operator-write` Kubernetes
auth role (create/update on exactly those two KV paths) and writes the KV v2 object — it never
uses the daemon's own read-only `prodbox-gateway-daemon` identity for the write. A missing JWT is
`401`, a failed Vault login is `403`, an unconfigured gateway Vault auth is `503`, and a Vault KV
write failure is `502`.

The host side (`Prodbox.Gateway.Client.writeOperatorSecret`) mints the JWT with
`kubectl create token prodbox-operator-write --namespace gateway` and posts the field map.
`Prodbox.Aws.writeOperatorSecretViaDaemonOrHost` prefers this daemon path and falls back to the
host root-token Vault write only when no operator service-account token can be minted yet or an
explicit unit/integration host-vault seam is active. Once the operator JWT exists, a daemon
rejection or transport failure is authoritative and does not bypass to a host root-token write.

### Historical Pre-Vault Bootstrap Endpoint (`POST /v1/bootstrap/vault/ensure`, Legacy Cutover Surface)

This gateway route is a historical implementation record and an explicit
[Standard-P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure)
rollback path.
In the target architecture the Bootstrap Broker is the only pre-Vault process and sole owner of
bounded init/unlock/seal/rotation; Gateway Runtime never receives an unlock proof or calls the
bootstrap object store. Bootstrap paths are absent from the compiled `GatewayRoute` registry,
gateway client, and `JournalLeaseEmitter` dispatch. The combined wrapper consults the separately
registered `Prodbox.Bootstrap.Broker.LegacyAdapter` only while the mutually exclusive
`LegacyModelBEmitter` topology is selected; there is no target/legacy dual write.

The rollback adapter preserves the old deliberately small pre-Vault REST surface so current
operators retain an explicit rollback while replacement qualification is pending. Historically it
let the host binary use the Kubernetes control plane only for initial substrate bootstrap and
daemon deployment; once MinIO, Vault, and the daemon NodePort were up, further host requests went
through the daemon service.

The endpoint accepts one bounded request carrying the operator/test unlock-bundle password, never
logs or echoes it, and performs the remaining steps in-cluster:

- read the password-AEAD-sealed unlock bundle from MinIO through
  `minio.prodbox.svc.cluster.local`;
- initialize Vault if the retained Vault PV is empty, preserving init-once semantics;
- submit Shamir unseal shares to Vault through the in-cluster Vault Service;
- run the baseline Vault reconcile after Vault is unsealed.

The daemon must not have standing authority to unseal Vault. It holds no persisted operator
password, no persisted plaintext unseal shares, and no alternate secret store that can reconstruct
the shares while Vault is sealed. A sealed Vault still bricks the cluster until fresh operator/test
input arrives. The endpoint is reachable only through the loopback-restricted NodePort described in
§12.1, with the firewall restriction treated as mandatory for this password-bearing route.

Sprint `2.29` implemented the pre-Vault bootstrap mode by decoding the daemon's non-secret boot/live
fields without resolving Vault-backed event keys, AWS credentials, or MinIO credentials. The REST
listener can therefore bind diagnostics and this endpoint before those Vault-resolved fields are
available. Sprint `4.42` routed root Vault lifecycle through this daemon boundary; Sprint `7.30`
added the same daemon boundary for supported Pulumi/object-store paths. Those statements describe
the rollback implementation, not target Gateway authority.

### `GET /healthz`, `GET /readyz`, and `GET /metrics`

The gateway REST listener also exposes daemon-health endpoints on the same in-pod REST port:

- `/healthz` is a constant-time read of the process-alive lifecycle flag and returns `200 ok` while
  the listener can serve.
- `/readyz` is a constant-time read of one pure readiness projection and returns `200 ready` only
  after the daemon enters `serve`, its managed gateway sessions and emitter actor are usable, and
  documented queue lanes can admit work. The rollback topology retains its validated continuity
  startup latch. The target topology instead requires the current encrypted-journal lock and
  matching Kubernetes Lease witness after successful recovery; Lease loss returns `503 starting`
  until reacquisition and recovery complete. After SIGTERM or SIGINT it returns `503 draining`
  during the bounded drain window.
- `/metrics` emits Prometheus exposition text from `envMetrics`, including bounded signed-replay and
  semantic-member gauges plus peer-connectivity and heartbeat-age gauges.

Neither health endpoint may inspect or sort semantic state, encode `/v1/state`, contact Vault,
MinIO, Route 53, or peers, or spawn a subprocess. `/readyz` is only a cached read of the readiness
projection over the Gateway Runtime's drain phase, current emitter-authority witness, and worker
inputs; authority acquisition/recovery happens outside the handler, and deep diagnostics stay on
the state route. A dependency requirement is resolved to an operation-indexed `CapabilityRef`, and that same
opaque reference is used for observation, admission, and execution—never a separately injected
probe endpoint. Sustained restart/OOM stability is observed by the test harness over a window.
These are distinct facts; the capability and readiness algebra is owned by
[Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md) and
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

These constant-time endpoints landed in Sprint `2.10`; Sprint `2.31` preserved their independence
and added a source regression guard proving that state traversal, sorting, or encoding cannot enter
either route.

The pure readiness projection supersedes the earlier unconditional serve-start readiness write.
Readiness is computed over drain phase, current emitter authority, and worker inputs; the lifecycle
gate keeps its end-to-end capability round trip and `/readyz` precheck, so lifecycle-ready implies
kubelet-ready by construction. Sprint `2.34` owns the compiled projection and rollback latch;
Sprint `2.32` owns the journal/Lease authority refinement in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md).

Filesystem readiness markers and `sd_notify` are not supported readiness signals. The
`prodbox-daemon-lifecycle` Cabal stanza starts the real `prodbox gateway start` process, waits on
`/readyz` through the shared retry helper, observes drain readiness after SIGTERM, and asserts
exit `0` after the configured drain deadline or a second SIGTERM. The style suite rejects direct
`threadDelay` and raw `terminateProcess` use in that lifecycle stanza. The same stanza captures
stable `/healthz`, ready/draining
`/readyz`, and normalized `/metrics` response-shape goldens under `test/golden/daemon-health/`.

The gateway chart binds Kubernetes liveness to `/healthz` and readiness to `/readyz` through the
typed/generated probe-values surface landed in
[Sprint 3.25](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md); chart lint rejects
`/v1/state` in either position.

---

## 12. Deployment Model

The canonical steady state for the gateway daemon is the in-cluster
`prodbox charts reconcile gateway` workload. The chart at `charts/gateway/` renders
one stable StatefulSet identity per ranked node id, each backed by a per-node `gateway-<id>`
Service, an orders ConfigMap, a per-node config ConfigMap, a cert-manager-issued
TLS material set, one identity-bound retained emitter-journal PVC, and the secret or config inputs
required by the daemon at runtime.
The daemon exposes `/healthz` and `/readyz` for liveness/readiness and keeps `/v1/state` as the
operator-facing state surface consumed by `prodbox gateway status`. The chart renders both kubelet
probes from the typed `GatewayProbeSpec` values: `/healthz` for liveness and `/readyz` for
readiness. Sprint `3.25` changed only that chart binding and did not change the landed daemon
endpoint contract.

This is the target workload contract, not evidence that the physical chart has cut over.
Sprint `2.32` supplies the typed claim-side persistence inputs in
`Prodbox.Gateway.Emitter.Persistence`: stable StatefulSet identity, the node-pinned retained home
claim, the static retained EKS `ReadWriteOncePod` claim, and exact Lease RBAC. Sprint `3.26` owns
their consumption into workload templates, PVs, EBS `volumeHandle`s, and `Retain` rendering.
Production-default and deployment-qualification status remain owned only by the Development Plan.

Gateway Runtime has no pre-Vault mode in the target topology. Bootstrap Broker is a distinct
Deployment, Service, ServiceAccount, Vault/MinIO policy, queue, resource envelope, and readiness
identity; it alone accepts the bounded bootstrap requests needed before Vault is unsealed. The
same-binary pre-Vault gateway mode and routes remain usable only through the isolated
`LegacyModelBEmitter`/`LegacyAdapter` rollback boundary.
[Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure)
retains that explicit rollback
until the replacement is the sole supported route and current-revision deployment qualification is
proven; cutover and deletion status are owned by the Development Plan.

The separate binary role is `prodbox bootstrap-broker start` with
`--config /etc/bootstrap-broker/config/config.dhall`. Its code-local production boundary remains fail closed
apart from liveness until Sprint `3.26` supplies TokenReview, Lease, Kubernetes workload, MinIO,
Vault, and OpenPGP adapters and renders that Deployment. This section therefore specifies the
failure-domain split without asserting that the replacement workload is deployed or qualified.

`prodbox gateway start --config <path>` is the Haskell daemon entrypoint and remains the in-pod
startup path invoked by the gateway chart's container. `prodbox gateway status --config <path>`
queries that same HTTP `/v1/state` endpoint for operator inspection, and
`prodbox gateway config-gen <path> --node-id <id>` provides template generation. Direct
host-process invocation remains a development mode, not the supported steady state.

Containerization is first-class for integration/runtime image publishing:

- `prodbox cluster reconcile` builds the single union runtime image from `docker/prodbox.Dockerfile`
  (the gateway runs it via `gateway start`); it deploys the gateway chart only after the exact
  Gateway-DNS credential generation, role-scoped config projection, and local journal capability
  are admitted. A missing Gateway-DNS generation blocks only DNS mutation; it cannot silently
  substitute the Lifecycle-provider or cert-manager identity
- the publish path runs an ordinary host-native `docker build`, then pushes the resulting registry
  tags from the repo-owned single-stage `ubuntu:24.04` Dockerfile with in-image `ghcup` and
  pinned GHC `9.12.4`
- The in-cluster registry (registry:2) is the supported source for the gateway workload image, and the host-arch variant is
  pulled back into local Docker before import into the RKE2 containerd cache
- Kubernetes pod integration tests run against that registry-published image by default
- The gateway workload image reference is pinned in code (the canonical
  `127.0.0.1:30080/prodbox/...` registry ref, shared across both substrates),
  not selected by an operator config field or environment variable. There is
  no `gateway.image_override` (or equivalent) config knob — the Dhall config
  carries no image field, and image pinning is a code constant, not operator
  input

See [Local Registry Pipeline](./local_registry_pipeline.md) for the registry install,
native-host-architecture publish flow, explicit public-image reconcile, and RKE2 registry behavior.

### CLI Management

```bash
prodbox gateway start --config <path>         # In-pod daemon entrypoint
prodbox gateway status --config <path>        # Query running daemon
prodbox gateway config-gen <path> --node-id <id>  # Generate template config
prodbox charts reconcile gateway                 # Install/upgrade in-cluster gateway workload
prodbox charts status gateway                 # Inspect installed gateway release
```

### 12.1 Host-CLI Access via 127.0.0.1-Only NodePort

The gateway chart renders two Services per ranked node: the existing per-node
`gateway-<id>` ClusterIP for in-cluster callers (chart pre-install Jobs, peer-mesh
traffic) and an additional NodePort Service that exposes the REST listener for host-CLI
access. The NodePort is restricted to `127.0.0.1` on the operator host via a host
iptables rule installed by `prodbox cluster reconcile` and removed by `prodbox cluster
delete --yes`. External access (LAN, WAN) is dropped at the host firewall.

The loopback restriction remains a defense for host access to gateway diagnostics. Historically it
also guarded the password-bearing gateway bootstrap route; the target Bootstrap Broker has its own
bounded transport and identity and the gateway NodePort carries no unlock proof.

The supported gateway host CLI calls the gateway exclusively through the native Haskell HTTP client in
`Prodbox.Http.Client` and the typed gateway client in `Prodbox.Gateway.Client`. Some current
test/workload/lifecycle call sites still use the legacy host `curl` shell-out pattern; Sprint `2.17` and the
legacy-removal ledger own its deletion.

Authoritative contract and bootstrap order for secrets now live in
[Secret Derivation Doctrine](./secret_derivation_doctrine.md), which describes the Vault-only
model.

### 12.2 Gateway Storage Boundary

Gateway Runtime has no generic MinIO principal, Pulumi checkpoint API, lifecycle Model-B API, or
target-secret API in the target topology. Lifecycle Authority owns Model-B CAS, immutable
checkpoint references, leases/fences, operation journals, provider workflow, and delivery outbox.
Bootstrap Broker alone accesses the pre-Vault unlock-bundle store. Target Secret Agent alone owns
allowlisted generation-checked target Vault CAS/read-back. Any gateway object-store routes or
`prodbox-gateway` MinIO authority are historical migration surfaces; their removal status is owned
by the Development Plan.

The gateway's only durable state-write authority is its own encrypted identity-bound emitter journal on
an explicitly registered retained volume. Vault supplies a renewable journal-key session at
startup; the heartbeat hot path performs no Vault or MinIO call. The journal is bound to one
admitted emitter identity and contains exactly:

- the stable cluster/emitter identity, admission state, authenticated active and prior Orders
  digests, and current durable `EmitterIncarnation`;
- an immutable trusted genesis or authenticated checkpoint floor plus the committed fixed-width
  epoch/sequence/digest anchor;
- at most one staged assertion containing the transition kind, exact canonical signed bytes,
  previous digest, and next anchor;
- one bounded contiguous retained suffix of canonical committed assertions; and
- a bounded known-current-peer acknowledgement projection plus authenticated repair-floor checkpoint.

One actor exclusively owns `stage -> fsync -> publish -> commit -> fsync`. A crash before the first
durability barrier publishes nothing. Every recoverable signed phase is normalized to the durable-
stage boundary and re-fsyncs and republishes the exact retained bytes before rewriting commit and
completing the final projection fsync; recovery never synthesizes a replacement signature. A crash
after commit but before peer response republishes only records still waiting on a current peer.
Acknowledgements never delete committed chain links; compaction occurs only when an authenticated
checkpoint installs the exact prefix frontier as the new floor. Missing journal state after prior
admission is recovery failure, never permission to reset the epoch.

Cross-process exclusion is substrate-specific. EKS uses its static retained EBS CSI volume with
`ReadWriteOncePod`, the OS lock, durable incarnation, and Kubernetes Lease. Home `hostPath`/local PV
is CSI-free: the StatefulSet is pinned to the PV's node and relies on that node affinity plus the OS
lock, durable incarnation, and Lease; it does not claim that `ReadWriteOncePod` protects hostPath.
The actor publishes only while the cached lease remains inside its renewal deadline. First admission
uses the recoverable journal-first initialization plus conditional marker write/read-back transaction in
[Lifecycle Control-Plane Architecture §8](./lifecycle_control_plane_architecture.md#8-gateway-emitter-actor).

Remote Model-B continuity may exist only as an explicitly named adapter during the plan-owned
migration. It cannot introduce a second transition owner, and it is removed after journal cutover.
Implementation, cutover, legacy removal, and deployment-qualification status are recorded only in
the Development Plan.

### 12.3 Runtime Memory Contract

The Kubernetes memory limit is an admission and containment boundary, not a static proof of the
daemon's arbitrary allocation behavior. The gateway has a separate validated runtime-memory plan:

```text
bounded semantic state
+ one bounded staged assertion and one bounded retained journal suffix
+ bounded in-heap transport/decode/in-flight scratch
+ other Haskell heap reserve
<= GHC heap cap

GHC heap cap
+ native/non-heap and out-of-heap transport reserve
+ bounded native TLS/socket/session-manager reserve
+ kernel/cgroup reserve
+ safety margin
<= container memory limit
```

Every summand is a unit-specific positive value. The two-level inequality avoids counting
Haskell-resident semantic/transport values both as sub-budgets and again beside the heap cap. The
pure validator rejects a sub-budget that exceeds the heap or an outer plan that exceeds the
container envelope; chart/runtime rendering derives the RTS heap policy and transport bounds from
the validated plan. Orders `max_members` and its per-member bounds determine the semantic-state,
signed replay, hot repair-checkpoint, peer-cursor, and retained-suffix maxima; persistence-first
publication permits at most one staged local transition. Gateway Runtime
spawns no operational subprocess on the target path; the native DNS/peer clients have fixed
in-flight and buffer bounds included in the transport/session reserves. The RTS heap cap leaves
headroom for non-heap memory and native client buffers; it does not replace semantic or transport bounds.
Conversely, an authored `512Mi` cgroup limit does not prove that an unbounded list will remain below
`512Mi`.

Runtime observation closes the boundary that static validation cannot.
`Prodbox.Test.GatewayRuntimeStability` purely projects Pod, Event, and metrics JSON into an exhaustive
gateway-pod observation and a run-wide result. OOM residue, restart increase, failure-threshold
high-water pressure, and unobservable authoritative state are absorbing: once observed during a run
they cannot be cleared by replacement or planned rollout. Warning pressure, Pending, and Pod UID
replacement reset consecutive success. The complete healthy-window baseline may otherwise reset
only for a gateway rollout present in the compiled restore/lifecycle plan, and it cannot erase the
absorbing result. A replacement StatefulSet being currently `Ready` is therefore not evidence
against an earlier fatal observation. The authoritative proof boundary and aggregate resource
algebra are in
[Resource Scaling Doctrine](./resource_scaling_doctrine.md); the time-windowed oracle is in
[Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md) and
[Unit Testing Policy](./unit_testing_policy.md).

`Prodbox.TestValidation` owns the complementary effect boundary: a structured continuous observer
and explicit rollout/final samples serialize through one concurrency-safe recorder. An explicit
baseline hands off to the observer's completed first sample before later suite actions run. AWS
uses a monitor-private EKS kubeconfig and explicit Vault-derived subprocess environment. Its
gateway reconcile and point sample precede the monitor handoff; SMTP synchronization and dependent
chart reconciles follow it. Only a compiled planned home/target gateway rollout may pause the
observer and drain an in-flight read; the post-reconcile sample precedes resume, and no pause or
healthy-window reset changes the absorbing result. Every stability `kubectl` read carries
`--request-timeout=5s` under both GNU `timeout` and `System.Timeout` wall-clock bounds. Logs remain
diagnostic-only.

Whole observed-cluster replacement, including `eks-volume-rebind`, uses a separate typed boundary:
pause/drain, pre-sample/reset, recreate, and on AWS the canonical gateway/platform reconcile. A
refresh request is acknowledged only after the worker leaves the old kubeconfig bracket and
materializes a new one. The runner then takes a foreground sample while the monitor remains paused
and resumes continuous observation only after success. The refresh never mutates or clears
absorbing evidence.

The decomposition/RTS policy is implemented in
[Sprint 1.60](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md),
and the gateway-specific bounded consumers and capacity-one runtime enforcement are implemented in
[Sprint 2.31](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md).

---

## 13. Verification Surfaces

Gateway verification lives in five canonical places:

1. `test/unit/Main.hs` for bounded semantic folds, cursor/delta/snapshot convergence, frame and
   memory-plan bounds, credential-gated DNS planning, daemon logic, and rendering.
2. `test/daemon-lifecycle/Main.hs` for process-level startup, readiness, signal drain,
   and daemon flag/env precedence coverage.
3. `prodbox test integration gateway-daemon` for daemon-oriented validation of startup, health,
   and status behavior.
4. `prodbox test integration gateway-pods` for pod-backed mesh validation and the Sprint `5.16`
   run-wide restart/OOM/high-water recorder, structured continuous monitor, and final stability
   gate.
5. `prodbox dev tla-check` plus `documents/engineering/tla/gateway_orders_rule.tla`
   for formal safety checks.

Property coverage proves that duplicate or reordered bounded deltas do not increase retained
cardinality, snapshot repair is semantically equivalent to applying the retained delta sequence,
and every admitted state remains within its configured cardinality/byte bounds. Continuity tests
additionally prove journal-first initialization followed by marker write/read-back, authenticated
journal resume when a crash lands between them, fail-closed inverse marker/journal mismatch, exact
durable-stage rewind and republication from every signed phase, migrated-projection/pre-publication
re-arm, conditional-write serialization of overlapping emitter incarnations, fixed-width sequence
exhaustion followed only by a durably acknowledged epoch rotation, safe-anchor recovery after
simultaneous restart of all peers, and fail-closed behavior for missing/corrupt/unreachable
authority. There is no audit tail to recover; the mandatory local continuity record may not be
absent after first admission. Sprint
`5.16`'s post-refresh stability classifier/monitor/gate is covered by 17/17 focused unit tests, 2/2
built-frontend `gateway-pods` fixtures (healthy and a background-only OOM retained through later
healthy samples), 1494/1494 full unit tests, and the exact post-refresh full CLI integration suite
at 47/47. `prodbox dev check` passes as the final repository closure gate. The live multi-peer substrate
soak remains a non-blocking Standard-O proof item.

---

## Daemon Lifecycle

The prodbox gateway daemon — and any other long-running daemon hosted by the
same binary — follows a shared lifecycle, observability, and configuration
discipline. This section is the SSoT for that discipline.

### What carries over unchanged

Daemons share the same architectural spine as one-shot commands:

- Library-first project layout, thin `Main.hs`.
- Typed `Command` ADT — the daemon is launched by a `Command` constructor
  like any other (e.g. `ServiceCommand`, `DaemonStartCommand`).
- `CommandSpec` registry — daemon-launching commands appear in
  `tool --help` and generated docs like any other.
- Generated-artifacts discipline — daemon config schemas, route inventories,
  and generated CLI sections still go through the marker/registry pattern.
- Lint/format stack — applies to daemon code identically.
- `tool test all` runs daemon lifecycle tests alongside everything else.

### Same-binary policy

The CLI and its daemons live in one binary. Rationale:

- Single distribution artifact, single dependency closure.
- Shared types, config loader, logger, error type — no duplication.
- The CLI introspects the daemon's command surface, generates its docs, and
  runs its tests through the same machinery.
- Operators learn one binary, not two.

### The daemon-as-Command pattern

A daemon is launched by a typed `Command` constructor that dispatches to a
daemon entry function:

```haskell
-- Example: daemon command dispatch shape
data Command
  = ...
  | ServiceCommand ServiceOptions
  | ...

runCommand :: Env -> Command -> IO ()
runCommand env = \case
  ...
  ServiceCommand opts -> Daemon.run env opts
  ...
```

Daemons do not have their own argv parser. CLI parsing is performed once,
in the same `optparse-applicative`-driven entry point used for every other
command.

### Lifecycle: load → prereq → acquire → ready → serve → drain → exit

Every daemon follows a seven-step lifecycle, expressed as nested `bracket`
and `withAsync`:

```text
1. Load and validate configuration   (fail fast on bad config)
2. Check prerequisites                (typed DAG; see Prerequisite Doctrine)
3. Acquire resources                  (bracket: open pools, connections, files)
4. Signal readiness                   (HTTP /readyz)
5. Serve / process                    (workers run inside withAsync)
6. Drain on shutdown signal           (SIGTERM/SIGINT triggers a TMVar)
7. Release resources and exit cleanly (bracket release runs in reverse order)
```

- **Configuration load** happens once at startup. Fail-fast on parse or
  validation error with a clear stderr message and non-zero exit. Daemons
  do not silently default away missing config.
- **Prerequisite check** runs the typed DAG defined in
  [prerequisite_doctrine.md → Prerequisites as Typed Effects](./prerequisite_doctrine.md#prerequisites-as-typed-effects)
  between `load` and `acquire`. A single unmet node aborts before any
  resource is acquired.
- **Resource acquisition** uses `bracket` (or `bracketOnError`) so cleanup
  runs on every exit path, including exceptions. Resources with external
  side effects — DB connections, file locks, message-broker consumer
  registrations — are released even on crash.
- **Readiness signaling** is HTTP `/readyz`. Every daemon exposes it; it
  returns 200 only while the daemon's readiness projection admits —
  startup complete plus the current cached authority facts its doctrine
  requires. The gateway rollback topology latches validated continuity
  startup; its target topology requires a current journal/Lease/recovery
  witness and may return to 503 on Lease loss. Drain always returns 503.
  Filesystem readiness markers and `sd_notify(READY=1)` are forbidden.
  `threadDelay` "wait long enough" probes are forbidden. Polling logs for
  a ready string is forbidden.
- **Serving** uses `Control.Concurrent.Async` (`withAsync`, `race`,
  `concurrently`, `replicateConcurrently`). `forkIO` is forbidden in
  daemon code: it cannot be cancelled, cannot propagate exceptions, and
  leaks on shutdown.
- **Shutdown** is signal-driven. The daemon installs handlers for SIGTERM
  and SIGINT that fill a shared `TMVar ()`. The main loop and workers
  observe the signal via `race` or an STM `check`. SIGTERM begins a
  graceful drain; a second SIGTERM (or SIGKILL) terminates immediately.
- **Drain semantics**: stop accepting new work, finish in-flight requests
  up to a bounded deadline (default 30s), then close. Drain is bounded; an
  indefinite drain is a hang.

### Structured concurrency

- Use `Control.Concurrent.Async` (`withAsync`, `concurrently`, `race`,
  `replicateConcurrently`) for any work that outlives a single function
  call.
- Use `bracket` / `bracketOnError` for resource acquisition.
- `forkIO` is forbidden in daemon code.
- Worker loops that restart on transient error use a `try`/`catch` plus
  bounded retry-with-backoff wrapper, not naked `forever`.

### Error handling: recoverable vs fatal

The CLI doctrine's `AppError` ADT treats errors as terminal. Daemons add a
second axis:

```haskell
-- Example: structured daemon error shape
data AppError = AppError
  { errorKind  :: ErrorKind
  , errorMsg   :: Text
  , errorCause :: Maybe SomeException
  }

data ErrorKind
  = Recoverable   -- retry with backoff inside the worker loop
  | Fatal         -- propagate to top level, drain, exit non-zero
```

Worker loops handle `Recoverable` errors by logging at warn level and
retrying with exponential backoff (capped). `Fatal` errors propagate to
the top-level supervisor, which begins drain and exits.

### Logging and observability

- Structured logging is mandatory for daemons. Logs go to stderr as JSON
  lines with timestamp, level, message, and a context bag. The doctrine
  prescribes `co-log` as the logger library. `putStrLn` is forbidden in
  daemon code paths.
- Log levels are first-class: `debug`, `info`, `warn`, `error`. Daemons
  start at `info` by default; the level is set by the Dhall `--config`
  file at startup and refreshed from `LiveConfig` on every file-watch
  reload (see [config_doctrine.md](./config_doctrine.md)).
- The logger lives in `Env`. All daemon code paths take `MonadReader Env`
  (or receive `Env` explicitly) so log calls attach contextual fields
  without rethreading.
- Health endpoints. Every daemon exposes both:
  - `/healthz` (liveness) — 200 when the process is alive.
  - `/readyz` (readiness) — 200 only while the readiness projection admits; 503 during drain.
- Metrics. Every daemon exposes `/metrics` in Prometheus exposition format.

### Structured logging field helpers

```haskell
-- Example: structured logging helper shape
field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)
field key value = (key, Aeson.toJSON value)

logStructured :: Text -> Text -> [(Text, Aeson.Value)] -> IO ()
logStructured level event details = do
    now <- getCurrentTime
    LBS8.hPutStrLn stderr . Aeson.encode . Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText "timestamp", Aeson.toJSON now)
            , (Key.fromText "level", Aeson.toJSON level)
            , (Key.fromText "event", Aeson.toJSON event)
            , (Key.fromText "details", Aeson.Object $
                KeyMap.fromList $
                    fmap (\(k, v) -> (Key.fromText k, v)) details)
            ]

logDebug, logInfo, logWarn, logError :: Text -> [(Text, Aeson.Value)] -> IO ()
logDebug = logStructured "debug"
logInfo = logStructured "info"
logWarn = logStructured "warn"
logError = logStructured "error"
```

**Forbidden patterns:**

- `putStrLn` or `print` for logging in daemon code.
- Format strings (`printf`-style) instead of structured fields.
- Untyped field construction (`[("key", toJSON value)]` without the `field`
  helper).
- Logs to stdout (reserved for daemon protocol surfaces or unused).

### The Env record grows

For daemons the prescribed baseline `Env`:

```haskell
-- Example: daemon application environment
data Env = Env
  { envBootConfig :: BootConfig       -- immutable after startup
  , envLiveConfig :: TVar LiveConfig  -- hot-reloadable
  , envLogger     :: Logger           -- structured, level-aware
  , envMetrics    :: MetricsRegistry  -- typed
  , envShutdown   :: TMVar ()         -- signals graceful drain
  , envResources  :: Resources        -- pools, clients, broker handles
  }
```

`Env` is built once during the lifecycle's "acquire" phase, threaded via
`ReaderT Env IO`, and torn down in reverse order. Global `IORef`s for any
of these are forbidden — they belong in `Env`. The split between
`envBootConfig` (plain value) and `envLiveConfig` (`TVar`) is load-bearing:
"which settings can change at runtime" is a property of the Haskell type,
not prose.

### Test hooks in Env

Test hooks are fields in the `Env` record that allow tests to observe or
control async behavior without mocking via typeclasses. Production
environments use no-op hooks; tests inject hooks to observe timing, trigger
events, or control concurrency.

```haskell
-- Example: application environment with injected test hooks
data Env = Env
    { envBootConfig :: BootConfig
    , envLiveConfig :: TVar LiveConfig
    , envLogger :: Logger
    , envMetrics :: MetricsRegistry
    , envShutdown :: TMVar ()
    , envResources :: Resources
    -- Test hooks (no-op in production)
    , envAfterConsumerClaim :: UUID -> IO ()
    , envBeforeMessageAck :: MessageId -> IO ()
    , envOnConnectionEstablished :: ConnectionId -> IO ()
    }
```

Production `mkProductionEnv` initializes hooks to `const (pure ())`; tests
inject observable variants.

**Forbidden patterns:**

- Mocking subsystem behavior via typeclasses when simple hooks suffice.
- Global `IORef`s for test coordination instead of `Env` fields.
- Hooks that change production behavior (all hooks must be no-ops in
  production).
- Tests that rely on `threadDelay` instead of hooks for timing.

### Configuration: Dhall file with mandatory file-watch reload

Configuration is a single `.dhall` file on the filesystem. YAML, JSON, and
TOML for daemon config are forbidden.

**Boot vs Live configuration.** Split the config record at compile time:

```haskell
-- Example: boot/live configuration split
data Config = Config
  { configBoot :: BootConfig
  , configLive :: LiveConfig
  }

data BootConfig = BootConfig
  { bootListenHost    :: Text
  , bootListenPort    :: Word16
  , bootConnPoolSize  :: Int
  , bootSchemaVersion :: Natural
  }

data LiveConfig = LiveConfig
  { liveLogLevel     :: LogLevel
  , liveRateLimits   :: Map Text RateLimit
  , liveFeatureFlags :: Map Text Bool
  , liveRouting      :: RoutingTable
  }
```

Both classes survive; only the response to a change differs. `LiveConfig`
fields hot-reload via atomic STM swap. `BootConfig` fields trigger a
drain-and-exit so the kubelet (or other supervisor) restarts the process
against the new file. The reload trigger, classification, and restart
contract are owned by [config_doctrine.md](./config_doctrine.md) — this
section defers to that SSoT for the operational details and only restates
the contract relevant to the gateway daemon implementation:

- The daemon watches its `--config` path via filesystem-watch primitives
  (the supported library is named by the implementing sprint). The same
  `TBQueue ()` reload-worker the implementation already drains is fed by
  the file watcher; the previously-supported SIGHUP signal handler is
  removed. See [config_doctrine.md §7](./config_doctrine.md#7-file-watch-reload-trigger).
- On detection of any change, the worker re-decodes the Dhall in-process
  via `Dhall.inputFile auto`. Decode failures log
  `config_reload_decode_failed` and leave the running config in place.
- Decode success with LiveConfig-only diffs atomically swaps
  `envLiveConfig` via STM and publishes on the existing broadcast
  channel.
- Decode success with any BootConfig diff logs
  `config_reload_boot_change_detected`, calls the existing drain
  machinery within `liveDrainDeadlineSeconds`, and exits with
  `ExitSuccess`. Pod-level restart-on-exit is the supervisor's
  responsibility, not the daemon's; see
  [config_doctrine.md §8](./config_doctrine.md#8-boot-vs-live-split-and-the-restart-contract).

**Atomic swap discipline.** `envLiveConfig` is `TVar LiveConfig`. `IORef`
for live config is forbidden. Workers read from the `TVar` at the start of
each request or batch — caching the dereferenced value across an
await/yield boundary is forbidden.

### CLI-to-daemon plumbing

Daemon-launching commands follow the same `CommandSpec` discipline as
everything else. The single startup-time CLI knob:

- `--config <path>` — path to the `.dhall` config file. The daemon refuses
  to start if the path does not exist or does not parse. Foreground
  execution is the only supported mode; the supervisor (systemd,
  Kubernetes, Docker) owns the process model.

`--log-level`, `--port`, `--node-id`, `--foreground`, `--detach`, and
similar runtime-override flags are not supported. Every value the daemon
needs lives in the Dhall file at `--config`. Environment-variable
precedence is forbidden on supported paths: no `PRODBOX_*` startup
fallback, no `<PROJECT>_<SETTING>` override ladder. See
[config_doctrine.md §10](./config_doctrine.md#10-forbidden-surfaces) for
the authoritative forbidden-surface list.

### Daemon lifecycle tests

A dedicated test category: spawn the daemon as a subprocess via
`typed-process`, poll `/readyz` until ready, exercise the protocol surface,
send SIGTERM, assert graceful shutdown within the configured drain
deadline, assert exit code 0. Forbidden test patterns:

- `terminateProcess` without first attempting graceful shutdown.
- `threadDelay`-based readiness probes.
- Polling for filesystem readiness markers when `/readyz` exists.

Health-endpoint response shapes (`/healthz`, `/readyz`, `/metrics`) belong
in the golden-test category. Shutdown signal tests assert that a single
SIGTERM begins drain and a second SIGTERM (or timeout) forces exit.

## Cross-References

- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
