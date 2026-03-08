# TLA+ Modelling Assumptions

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/distributed_gateway_architecture.md, PRODBOX_PLAN.md

> **Purpose**: Document the formal modelling decisions, correspondence mapping, known divergences, and verification boundaries for the gateway TLA+ specification.

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
| `live` | Process existence (running vs crashed) | `GatewayDaemon.start()`/`stop()` |
| `seenHeartbeatTs[viewer][peer]` | `_get_last_heartbeat()` from commit log scan | `gateway_daemon.py:1115` |
| `ownerView[n]` | `self._gateway_owner` | `gateway_daemon.py:1132` |
| `eventLog` | `self._commit_log.events` | `CommitLog` class |
| `dnsWriteNode` | `self._last_dns_write_ip` (side effect of write) | `gateway_daemon.py:923` |
| `msgQueue` | In-flight TCP messages (implicit) | Socket protocol |
| `activeOrderTs[n]` | `self._orders.version_utc` | Orders dataclass |
| `now` | `datetime.now(UTC)` | `_utc_now()` |
| `RankOrder` (constant) | `orders.gateway_rule.ranked_nodes` | Orders config |
| `Rank1`/`Rank2`/`Rank3` (constants) | Individual rank positions | TLC workaround for sequence literals |
| `NoTimestamp` (constant, -1) | `None` from `_get_last_heartbeat()` | Cold-start sentinel |

### Actions

| TLA+ Action | Implementation | Location |
|---|---|---|
| `Tick` | Wall clock progression | N/A (real-time) |
| `Crash(n)` / `Recover(n)` | Process kill / restart | K8s pod lifecycle |
| `SendHeartbeat(sender)` | `_heartbeat_loop()` | `gateway_daemon.py:880-887` |
| `DeliverHeartbeat` | TCP message arrival + commit log append | Socket protocol handler |
| `Heartbeat(s, r)` | Synchronous heartbeat (primary model checking action) | `_heartbeat_loop()` |
| `PromoteOrders(r, newTs)` | Orders file reload with higher `version_utc` | Orders validation |
| `RecomputeOwner(n)` | `_recompute_gateway_owner()` | `gateway_daemon.py:1108-1137` |
| `DnsWrite(n)` | `_attempt_dns_write()` | `gateway_daemon.py:900-930` |

---

## 3. Known Divergences

### Divergence 1: Election Algorithm — Resolved

**TLA+ model**: `LeaderFromUpSet` now uses `RankIndex(n)` based on `RankOrder == <<Rank1, Rank2, Rank3>>` — selects the highest-ranked node (lowest rank index) from the UpSet candidates. Includes cold-start self-preference: if a node hasn't been heartbeated yet (`seenHeartbeatTs[viewer][self] = NoTimestamp`), it adds itself to the candidate set.

**Implementation**: Uses rank-ordered iteration through `orders.gateway_rule.ranked_nodes` — first node in the configured rank list with a fresh heartbeat.

**Resolution**: Added `Rank1`/`Rank2`/`Rank3` individual constants (TLC config files cannot express sequence literals), constructed as `RankOrder == <<Rank1, Rank2, Rank3>>` in the spec. `RankIndex(n)` returns the position in this sequence. `LeaderFromUpSet` selects `CHOOSE x ∈ candidates : ∀ y ∈ candidates : RankIndex(x) ≤ RankIndex(y)`.

### Divergence 2: DNS Write Yield Guard — Resolved

**TLA+ model**: `CanWriteDns(n)` requires `HasClaim(n) ∧ ¬HasYieldAfterLastClaim(n)`. A node must have an active claim with no subsequent yield in the event log.

**Implementation**: `_attempt_dns_write` now calls `has_active_claim_from(node_id)`, which checks that the node has a `gateway_claim` event in the commit log with no subsequent `gateway_yield` — matching the TLA+ `CanWriteDns` guard exactly.

**Resolution**: Added `has_active_claim_from(node_id)` method to `GatewayDaemon` and updated `_attempt_dns_write` to use it. The original `has_claim_from()` is retained for test assertions checking event presence. Six dedicated regression tests in `TestHasActiveClaim` cover cold start, claim, yield, reclaim, cross-node isolation, and the race condition scenario.

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

Under severe partition, the implementation chooses safety-first: nodes self-elect as failsafe (satisfying `SingletonTakeover`), accepting temporary split-brain that heals on reconvergence. This is documented in [Distributed Gateway Architecture Section 5](./distributed_gateway_architecture.md#5-safety-boundary-important).

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
| Model-implementation correspondence audit | **This document** |

### Running the Model Checker

```bash
poetry run prodbox tla-check
```

This runs TLC 2.18 in a Docker container (`maxdiefenbach/tlaplus`) with 8 workers and writes results to `documents/engineering/tla/tlc_last_run.txt`.

---

## Cross-References

- [Distributed Gateway Architecture](./distributed_gateway_architecture.md) — system design and protocol spec
- [TLA+ Model](./tla/gateway_orders_rule.tla) — formal specification
- [TLA+ Config](./tla/gateway_orders_rule.cfg) — model checking bounds
- [Documentation Standards](../documentation_standards.md) — document format requirements
