# TLA+ Modelling Assumptions

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md

> **Purpose**: Document the formal modelling decisions, correspondence mapping, known divergences, and verification boundaries for the gateway TLA+ specification.

---

## 0A. Planning Ownership

This document owns modelling assumptions, implementation correspondence, and divergence tracking
only.

Sprint sequencing, completion status, remaining work, validation closure, and cleanup ownership
for the gateway/TLA surfaces are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

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

The spec contains both synchronous heartbeats (`Heartbeat(s, r)`) and async heartbeats via `msgQueue` (`SendHeartbeat`/`DeliverHeartbeat`). Model checking uses synchronous heartbeats for tractable state space; the async actions are retained in the spec for reference. REST is not modelled — it exists only for mTLS handshake bootstrapping.

### What the model does NOT include

- **Real time**: The model uses discrete timestamps (`0..MaxTimestamp`), not wall-clock time.
- **TCP connections**: Transport-level details (connection establishment, teardown, partial writes) are abstracted away.
- **TLS handshakes**: mTLS authentication is assumed correct and not modelled.
- **Message ordering beyond append-only log**: The `msgQueue` is a set (unordered). Ordering comes from the event log sequence.
- **Network-level failures**: Only node crash/recover and message delay are modelled. TCP resets, partial writes, and connection timeouts are not represented.
- **Anti-entropy gossip**: The sync protocol that reconciles divergent event logs between peers is not explicitly modelled. The global `eventLog` abstracts this — in practice, anti-entropy ensures logs converge.

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
| `msgQueue` | Not materialized as a first-class runtime queue; transport is abstracted behind daemon loops and socket/REST boundaries | `src/Prodbox/Gateway/Daemon.hs` |
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
| `DeliverHeartbeat` | Abstracted in the current runtime surface; not materialized as a standalone queue action | `src/Prodbox/Gateway/Daemon.hs` |
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

The current Haskell runtime compresses that surface: it stores local heartbeat freshness in
`stateLastHeartbeatTimes`, keeps transport implicit behind daemon loops and socket/REST boundaries,
and does not expose a first-class runtime `msgQueue`.

### Divergence 3: Ownership Lifecycle Is More Explicit In The Model Than In The Current Runtime Surface

The target architecture and TLA+ model use `GatewayClaim` / `GatewayYield` as the formal
DNS-write gate.

The current Haskell daemon status surface exposes:

1. `stateGatewayOwner` as the in-memory owner view
2. `has_active_claim` rendered from `stateGatewayOwner state == Just (daemonNodeId config)`
3. `stateLastDnsWriteIp` / `stateLastDnsWriteTime` as the observed last successful write

Treat the event-log lifecycle in the model as the formal safety contract and the runtime fields as
the current operational projection. Phase closure and any remaining alignment work on that
boundary are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

---

## 4. Modelling Bounds and Limitations

### Configuration Values

| Bound | Value | Justification |
|---|---|---|
| `Nodes` | `{n1, n2, n3}` | 3 nodes is the minimum for non-trivial partition testing (majority vs minority). Matches the physical deployment target. |
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
prodbox tla-check
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
