# TLA+ Modelling Assumptions

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md
**Generated sections**: none

> **Purpose**: Document the formal modelling decisions, correspondence mapping, known divergences, and verification boundaries for the gateway TLA+ specification.

---

## 0A. Planning Ownership

This document owns modelling assumptions, implementation correspondence, and divergence tracking
only.

Sprint sequencing, completion status, remaining work, validation closure, and cleanup ownership
for the gateway/TLA surfaces are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

The authoritative verification contract distinguishes the formal
`prodbox dev tla-check` surface from the separate native
`prodbox test integration gateway-partition` surface. This document
describes the model and its correspondence only; current implementation
closure for those validation paths remains plan-owned.

---

## 1. Abstract System Model

The TLA+ specification (`documents/engineering/tla/gateway_orders_rule.tla`) models a set of peer nodes with crash-recovery semantics, delayed heartbeat delivery via full-duplex channels, ranked failover election, ownership claim/yield events, and DNS write gating.

### What the model includes

- **Node lifecycle**: Nodes may crash (`Crash(n)`) and recover (`Recover(n)`) non-deterministically. The `live` set tracks which nodes are currently running.
- **Heartbeat delivery**: Synchronous heartbeats via `Heartbeat(sender, receiver)` — sender's timestamp is recorded at the receiver, and sender refreshes its own self-timestamp. The spec also retains async heartbeat actions (`SendHeartbeat`/`DeliverHeartbeat` via `msgQueue`) for reference, but model checking uses synchronous heartbeats for tractable state space.
- **Cold-start detection**: `NoTimestamp` sentinel (-1) distinguishes "never heartbeated" from "heartbeated at time 0". Nodes start with self-heartbeat at 0 (past cold-start) but `NoTimestamp` for all peers.
- **Election**: Each node independently computes `ownerView[n]` via `LeaderFromUpSet(n, n)` using rank-ordered selection from the UpSet. Cold-start self-preference adds self to candidates when a node hasn't yet participated in the heartbeat protocol.
- **Ownership events**: `RecomputeOwner(n)` emits `GatewayClaim`/`GatewayYield` entries to the global `eventLog` when ownership changes.
- **DNS write gating**: `DnsWrite(n)` requires `CanWriteDns(n)` — the node must be self-computed owner AND have an active claim (no subsequent yield) in the event log.
- **Orders promotion**: `PromoteOrders(r, newTs)` models nodes receiving higher-versioned Orders documents.
- **Discrete time**: `Tick` advances a bounded clock (`now`), used for heartbeat timeout comparison.

### Communication model

The spec contains both synchronous heartbeats (`Heartbeat(s, r)`) and async heartbeats via
`msgQueue` (`SendHeartbeat`/`DeliverHeartbeat`). Model checking uses synchronous heartbeats for
tractable state space; the async actions are retained in the spec for reference. The operator-facing
HTTP `/v1/state` observability endpoint is not modelled.

In the runtime, peer transport is materialised as anti-entropy gossip:
each daemon periodically pushes its commit log to every other peer over
the configured peer-events port, and receivers update
`stateLastHeartbeatTimes` plus `statePeerHealth` from the inbound event
timestamps.  The event-log replication is therefore concrete in the
runtime even though the model abstracts it through a global `eventLog`
plus delayed delivery via `msgQueue`.

### What the model does NOT include

- **Real time**: The model uses discrete timestamps (`0..MaxTimestamp`), not wall-clock time.
- **TCP connections**: Transport-level details (connection establishment, teardown, partial writes) are abstracted away.
- **Peer transport establishment**: socket setup, trust-material
  consumption, and any later transport-auth expansion are abstracted
  away. The model starts from accepted peer batches plus runtime HMAC
  validation.
- **Message ordering beyond append-only log**: The `msgQueue` is a set (unordered). Ordering comes from the event log sequence.
- **Network-level failures**: Only node crash/recover and message delay are modelled. TCP resets, partial writes, and connection timeouts are not represented.
- **Anti-entropy gossip**: The sync protocol that reconciles divergent event logs between peers is abstracted through the global `eventLog`.  The runtime materialises this protocol concretely (`Prodbox.Gateway.Peer`, `peerListenerLoop`, and `peerDialerLoop`); the divergence between the model's global log and the runtime's per-node log is therefore narrowed to delivery delay only.

---

## 2. Variable-to-Implementation Correspondence

### Variables

| TLA+ Variable | Implementation | Location |
|---|---|---|
| `live` | Running `runGatewayDaemon` process and its active loops | `src/Prodbox/Gateway/Daemon.hs` |
| `seenHeartbeatTs[viewer][peer]` | `DaemonState.stateLastHeartbeatTimes` heartbeat freshness map | `DaemonState`, `heartbeatLoop`, `gatewayLoop` |
| `ownerView[n]` | `DaemonState.stateGatewayOwner` | `DaemonState`, `gatewayLoop` |
| `eventLog` | `CommitLog.commitLogEvents` carried in `DaemonState.stateCommitLog` | `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/Gateway/Daemon.hs` |
| `dnsWriteNode` | Last successful write tracked by `stateLastDnsWriteIp` / `stateLastDnsWriteTime` | `DaemonState`, `dnsWriteLoop` |
| `msgQueue` | Realised as inbound peer-event batches received over the events port; the receiver merges accepted events into the local commit log via `appendIfNew` | `src/Prodbox/Gateway/Peer.hs`, `peerListenerLoop` in `src/Prodbox/Gateway/Daemon.hs` |
| `activeOrderTs[n]` | `Orders.ordersVersionUtc` from the parsed Orders document | `src/Prodbox/Gateway/Types.hs` |
| `now` | `getCurrentTime` samples used by the daemon loops | `src/Prodbox/Gateway/Daemon.hs` |
| `RankOrder` (constant) | `GatewayRule.rankedNodes` | `src/Prodbox/Gateway/Types.hs` |
| `Rank1`/`Rank2`/`Rank3` (constants) | TLC-only constants used to build `RankOrder` during model checking | `documents/engineering/tla/gateway_orders_rule.cfg` |
| `NoTimestamp` (constant, -1) | Absence from `stateLastHeartbeatTimes` for a peer | `gatewayLoop` freshness logic |

### Actions

| TLA+ Action | Implementation | Location |
|---|---|---|
| `Tick` | Wall-clock progression sampled via `getCurrentTime` | `heartbeatLoop`, `gatewayLoop`, `dnsWriteLoop` |
| `Crash(n)` / `Recover(n)` | Process or pod stop/restart around `runGatewayDaemon` | `src/Prodbox/Gateway/Daemon.hs`, `charts/gateway/` |
| `SendHeartbeat(sender)` | `heartbeatLoop` appends local signed `heartbeat` events and refreshes local heartbeat time | `src/Prodbox/Gateway/Daemon.hs` |
| `DeliverHeartbeat` | `peerListenerLoop` accepts inbound peer event batches and updates `stateLastHeartbeatTimes` from the emitter timestamps | `src/Prodbox/Gateway/Peer.hs`, `peerListenerLoop` in `src/Prodbox/Gateway/Daemon.hs` |
| `Heartbeat(s, r)` | Model-only synchronous heartbeat step retained for tractable TLC exploration | `documents/engineering/tla/gateway_orders_rule.tla` |
| `PromoteOrders(r, newTs)` | Orders parsing and `ordersVersionUtc` promotion boundary | `parseOrders`, `runGatewayDaemon` |
| `RecomputeOwner(n)` | `gatewayLoop` recomputes owner from ranked fresh heartbeats | `src/Prodbox/Gateway/Daemon.hs` |
| `DnsWrite(n)` | `dnsWriteLoop` plus `fetchPublicIp` / `writeDnsRecord` | `src/Prodbox/Gateway/Daemon.hs` |

---

## 3. Known Divergences And Compression Points

### Divergence 1: Correspondence Surface Is Haskell-Only

The supported implementation surface is now the Haskell gateway and TLA entrypoint:

1. `src/Prodbox/Gateway/Daemon.hs`
2. `src/Prodbox/Gateway/Types.hs`
3. `src/Prodbox/Gateway.hs`
4. `src/Prodbox/Tla.hs`

Historical Python symbol names are no longer authoritative for model-to-implementation
correspondence and must not be treated as current repository facts.

### Divergence 2: Message Delivery Is More Explicit In The Model

The TLA+ model keeps both:

1. synchronous `Heartbeat(s, r)` for tractable model checking
2. asynchronous `SendHeartbeat` / `DeliverHeartbeat` actions over `msgQueue` for protocol
   reference

The current Haskell runtime now materialises the asynchronous variant
through `peerDialerLoop` (push) and `peerListenerLoop` (deliver).  Each
runtime push corresponds to a `SendHeartbeat`/`DeliverHeartbeat` step,
the receiver updates `stateLastHeartbeatTimes` from inbound event
timestamps, and the global `eventLog` is converged via idempotent
`appendIfNew`.  The remaining compression is the synchronous shortcut
the model uses for tractable TLC exploration.

### Divergence 3: Ownership Lifecycle Now Materialised In The Runtime

The TLA+ model uses `GatewayClaim` / `GatewayYield` as the formal
DNS-write gate. The runtime now emits the same events from
`gatewayLoop` on owner transitions and gates `dnsWriteLoop` through the
`canWriteDns` predicate.  The runtime invariants therefore align with
the model's `ClaimPrecedesWrite` and `YieldPrecedesReclaim`.

The current Haskell daemon status surface exposes:

1. `stateGatewayOwner` as the in-memory owner view
2. `has_active_claim` rendered from `stateGatewayOwner state == Just (daemonNodeId config)`
3. `can_write_dns` rendered from the runtime `canWriteDns` predicate
4. `node_disposition` and `peer_dispositions` derived from the commit log
5. `stateLastDnsWriteIp` / `stateLastDnsWriteTime` as the observed last successful write
6. total `event_count`, a bounded recent `event_hashes` tail, and `heartbeat_age_seconds` on
   `/v1/state` for operator and integration observability
7. `peer_inbound_health` (last accepted-event age per peer) and
   `peer_outbound_health` (per-peer dial connect state / last dial error),
   split so a one-directional partition is observable (Sprint 2.25; the prior
   conflated `peer_transport` field is retired)

Phase closure and any remaining alignment work on that boundary are
owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

### Divergence 4: Operator Time-Base Discipline Is Runtime-Enforced

The model's bounded-delay assumption is now mapped to a runtime-enforced
skew limit.  `prodbox host info` reports the host's NTP synchronization
disposition derived from `timedatectl` and fails fast when the system
clock is unsynchronized.  The gateway daemon refuses inbound peer
events whose timestamps lie beyond `daemonMaxClockSkewSeconds` (default
10 seconds) and records the maximum observed inter-node skew on
`/v1/state` as `max_clock_skew_seconds_observed`.

Validation surface note: today the only enforced constraint on
`daemonMaxClockSkewSeconds` is `validateNonNegative` — the value must be
≥ 0; there is no upper bound and no positive-floor check in code yet.
The intended bounded range `[0.1, 600]` (a positive floor so the skew
gate is never effectively disabled, and a ceiling that keeps the
bounded-delay correspondence honest) is scheduled doctrine, not a
current invariant. Until that smart-constructor bound lands, a
configured skew of `0` or an arbitrarily large value is accepted at
decode time; the modelling correspondence assumes the bounded range and
should not be read as describing enforced behaviour.

### Divergence 5: Orders Promotion Is Restart-Based, Not In-Process

The TLA+ `PromoteOrders(r, newTs)` action lets a running node advance
its active Orders version in place. The runtime does **not** do this:
`stateOrdersVersionUtc` is fixed at daemon boot from the Orders document
present at start and never advances while the process is live. A daemon
adopts a newer Orders only by restarting against the new document — the
restart-based promotion path defined in
[config_doctrine.md § 8 step 4](./config_doctrine.md). The model's
in-process `PromoteOrders` step therefore corresponds to a
boot-then-restart cycle in the runtime, not to a mutation of live state.

Orders documents carry the existing monotonic `version_utc` field. Each
peer push includes the sender's current view of that version. The
receiver returns `409 Conflict` when the sender's view is older,
preventing a stale peer from advancing the receiver's commit log behind
a newer Orders. The daemon tracks the highest observed Orders version on
`/v1/state` and refuses to claim ownership while
`stateLatestObservedOrdersVersion > stateOrdersVersionUtc` — the
refuse-to-reclaim-while-behind gate. Because the in-process version never
advances, a daemon that boots against a stale Orders stays refused until
it is restarted against the current document; it cannot reclaim DNS write
authority by observing a newer version at runtime.

Realigning the `PromoteOrders` action and any associated machinery to
the restart-based reality — and removing the dead in-process promotion
path — is owned by Sprint 2.25 in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

---

## 4. Modelling Bounds and Limitations

### Configuration Values

| Bound | Value | Justification |
|---|---|---|
| `Nodes` | `{n1, n2, n3}` | 3 nodes is the minimum for non-trivial partition testing (majority vs minority). This is the *multi-host* topology the model is written for — it does NOT match the current home deployment target, which is a single-host degenerate single-rank mesh (see the topology/fault-model note below). The 3-node bound exercises the partition-tolerance capability reserved for the AWS / future multi-host substrate. |
| `MaxTimestamp` | `2` | Bounds the state space for exhaustive TLC exploration. With 2 timestamps, heartbeat timeout of 2 allows one timeout cycle. Sufficient to demonstrate the invariants but does NOT prove properties over unbounded runs. |
| `HeartbeatTimeout` | `2` | Matches the smallest timeout that allows meaningful timeout expiry within `MaxTimestamp`. In production, `heartbeat_timeout_seconds` is typically 5-15 seconds. |
| `Rank1`/`Rank2`/`Rank3` | `n1`/`n2`/`n3` | Individual constants for rank ordering (TLC config files cannot express sequence literals). Constructs `RankOrder == <<n1, n2, n3>>`. |
| `StateConstraint` | `Len(eventLog) <= 3` | Bounds event log growth for tractable state space. Sufficient for claim-yield-reclaim sequences. |

### What the bounds prove

- All 6 safety invariants hold for ALL reachable states within the bounded state space (4,394,744 distinct states at MaxTimestamp=2, HeartbeatTimeout=2).
- `SingletonSelfElection` verified: sole survivor's election function always picks itself.

### What the bounds do NOT prove

- Properties over unbounded execution (infinite runs).
- Behavior with >3 nodes.
- Real-time constraints (the model uses discrete timestamps, not wall-clock time).
- Network-level failures (the model only models message delay, not TCP resets, partial writes, etc.).

### Topology and Fault Model

The model's 3-node ranked mesh with crash/recover and message delay is a
*multi-host* fault model. It does not describe the current home
deployment. The home substrate runs a **single-host degenerate
single-rank mesh**: a single gateway daemon on the one host this
machine is, with no peer to fail over to. Every component on that host
shares fate — if the host is down, the daemon, etcd, kubelet, and the
DNS-write authority all go down together. There is no partition to
tolerate, because there is no second host to be partitioned from.

Partition tolerance is therefore a **capability the model reserves for
the AWS / future multi-host substrate**, not a property the home
deployment exercises. The 3-node bound, the ranked-failover election,
the crash/recover actions, and the partition-heal reconvergence
(Section 6) all correspond to the multi-host case; on home they are
exercised only degenerately (a single rank-1 node that always
self-elects, satisfying `SingletonSelfElection`). Reading this document,
treat the partition-related invariants as proving the *intended*
multi-host behaviour the runtime is built toward — not as describing a
fault class the single-host home topology can actually enter.

This topology framing is kept consistent with the fault-model reframe in
[distributed_gateway_architecture.md § 7.5](./distributed_gateway_architecture.md),
owned by Sprint 2.25 in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

---

## 5. Invariant Catalog

| Invariant | Meaning | Failure Prevented |
|---|---|---|
| `DeterministicRuleForEqualViews` | Same orders + same heartbeat observations + non-empty UpSet → same computed owner | Split-brain from non-deterministic election |
| `NoTugOfWarWhenViewsConverged` | After views converge, at most 1 node publishes as gateway | DNS record flip-flopping between nodes |
| `NoSimultaneousDNSWriters` | When fully stable (converged views, current ownerView, non-empty UpSet), at most 1 node can write DNS | Concurrent conflicting DNS updates in steady state |
| `ClaimPrecedesWrite` | DNS write only after a claim in the event log | Stale writes from nodes that haven't asserted ownership |
| `YieldPrecedesReclaim` | A node must yield before claiming again | Re-entrant claims without proper transition tracking |
| `SingletonSelfElection` (safety) | Sole survivor's election function always picks itself | Election function failure for isolated nodes |

### Invariant Definitions

**`DeterministicRuleForEqualViews`**: For all node pairs `(a, b)` that are past cold start, have identical `activeOrderTs`, identical `seenHeartbeatTs`, and non-empty UpSet, then `LeaderFromUpSet(a, a) = LeaderFromUpSet(b, b)`. Uses the election function directly (not cached `ownerView`). With empty UpSet, self-election fallback is viewer-dependent by design (FLP impossibility).

**`NoTugOfWarWhenViewsConverged`**: When all past-cold-start nodes have converged views (same orders timestamps AND same heartbeat observations), at most 1 node has `LeaderFromUpSet(n, n) = n` with non-empty UpSet on the most recent Orders. This prevents DNS record flip-flopping during steady state.

**`NoSimultaneousDNSWriters`**: Conditional on `FullyStable` — views converged, ownerView current (matches LeaderFromUpSet), and all live nodes have non-empty UpSet. When stable, at most 1 live node satisfies `CanWriteDns`. Under partition (not FullyStable), FLP impossibility means multiple nodes may independently claim and write DNS. Anti-entropy gossip (not modeled) resolves this on partition heal.

**`ClaimPrecedesWrite`**: Every `dns_write` entry in the event log has a preceding `claim` entry from the same node. This ensures no node writes DNS without first asserting ownership.

**`YieldPrecedesReclaim`**: Between any two `claim` entries from the same node, there exists a `yield` entry from that node. This ensures proper ownership lifecycle tracking.

**`SingletonSelfElection`**: If a node is the sole survivor (`live = {n}`), `LeaderFromUpSet(n, n) = n`. This is a safety invariant verifying the election function's correctness — the sole survivor always self-elects. The implementation's periodic `gateway_loop` ensures `ownerView` is updated within milliseconds.

---

## 6. FLP Impossibility Acknowledgment

In a fully asynchronous system with partitions, the system cannot guarantee both absolute no-split-brain and always-available autonomous failover (Fischer, Lynch, Paterson, 1985).

The TLA+ model proves safety invariants under the modelled assumptions (bounded timestamps, crash-recovery, message delay). These invariants hold for all reachable states in the bounded state space.

Under severe partition, the implementation chooses safety-first: nodes self-elect as failsafe
(satisfying `SingletonSelfElection`), accepting temporary split-brain that heals on reconvergence.
This is documented in [Distributed Gateway Architecture Section 5](./distributed_gateway_architecture.md#5-safety-boundary-important).

The design contract:
1. `NoTugOfWar` and `NoSimultaneousDNSWriters` are proven for the fully-stable state (converged views, current ownerView, non-empty UpSet).
2. Under partition or cold start, `NoSimultaneousDNSWriters` does NOT hold unconditionally — FLP impossibility means isolated nodes independently self-elect and claim. TLC discovered this counterexample during model checking.
3. Under severe partition uncertainty, isolated nodes self-elect to maintain availability.
4. On partition heal, anti-entropy gossip ensures views converge and the deterministic election resolves to a single owner.

---

## 7. Verification Status

| Item | Status |
|---|---|
| TLA+ spec written | Complete (~340 lines) |
| TLC model checker execution | **Complete** — all 6 invariants verified over 4,394,744 distinct states (HeartbeatTimeout=2, MaxTimestamp=2) |
| CI integration | **Intentionally not used during active development** |
| Model-implementation correspondence audit | **Complete at the current Haskell module level; divergences are recorded in this document** |

### Running the Model Checker

```bash
prodbox dev tla-check
```

`src/Prodbox/Tla.hs` owns this public entrypoint. It runs TLC 2.18 in a Docker container
(`maxdiefenbach/tlaplus`) with 8 workers and writes results to
`documents/engineering/tla/tlc_last_run.txt`.

---

## 8. Model-vs-Test Coverage Boundary

The gateway failure space includes crash timing races, delayed heartbeats, asymmetric partitions, and rejoin ordering permutations. The combinatorics make exhaustive runtime testing infeasible.

This is the same class of limitation that led AWS to increase reliance on formal methods for systems such as S3 and DynamoDB: conventional test suites found many defects, but could not enumerate all distributed interleavings.

In prodbox:

1. TLA+ is used to prove bounded-state safety properties for partition semantics.
2. Runtime unit/integration tests are still mandatory to validate that implementation behavior matches the modelling assumptions and invariants.

---

## Cross-References

- [Distributed Gateway Architecture](./distributed_gateway_architecture.md) — system design and protocol spec
- [TLA+ Model](./tla/gateway_orders_rule.tla) — formal specification
- [TLA+ Config](./tla/gateway_orders_rule.cfg) — model checking bounds
- [Development Plan](../../DEVELOPMENT_PLAN/README.md) — phase status, closure, and cleanup ownership
- [Documentation Standards](../documentation_standards.md) — document format requirements
