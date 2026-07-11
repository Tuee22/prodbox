# TLA+ Modelling Assumptions

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/chaos_hardening_doctrine.md
**Generated sections**: none

> **Purpose**: Define the gateway model-to-runtime correspondence, the finite semantic-state and
> delta-protocol bounds explored by TLC, and the boundary between finite model domains and a
> production memory bound.

---

## 0A. Planning Ownership

This document owns modelling assumptions, implementation correspondence, and verification limits.
Sprint status, closure evidence, and remaining work are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

The formal entrypoint is `prodbox dev tla-check`. The separate native
`prodbox test integration gateway-partition` path validates runtime behaviour and does not delegate
to TLC.

---

## 1. Modelled System

The specification is
[`documents/engineering/tla/gateway_orders_rule.tla`](./tla/gateway_orders_rule.tla). It models a
bounded semantic gateway replica rather than an append-only event history.

Each configured node has fixed slots for:

1. one active Orders version and one promotion candidate
2. one latest assertion and receive cursor for every configured emitter
3. one overwriteable outbound delta slot for every directed peer link
4. one retained continuity anchor and semantic kind plus at most one exact staged assertion
5. two process-local booleans for exact-stage observation and publication acknowledgement
6. one current owner projection
7. a live credential-ready capability and continuity-observable capability

There is deliberately no `eventLog` variable. Repeated heartbeats, duplicate delivery, Orders
churn, and epoch rotation change values inside fixed slots; they do not add slots.

### 1.1 Per-emitter continuity

An emitter position is a fixed-width `(epoch, sequence)` pair. `StageAssertion` conditionally
records the exact next signed assertion and next anchor in the retained authority without
publishing it. `ReobserveStaged` records the process-local exact read-back witness.
`PublishStaged` advances the local semantic projection and bounded outbound delta slots but leaves
the retained stage intact. Only `CommitPublished` advances the committed authority anchor and
clears that stage after publication acknowledgement.

The distinction is intentional. `authorityPhase`, `staged*`, and the committed `authority*` fields
are retained. `stageObserved` and `publishAcknowledged` are volatile process memory. `Crash` clears
both volatile witnesses, all local semantic/cursor state, credentials, promotion work, and peer
frame slots involving the crashed process while preserving the retained authority. Therefore a
crash after staging emits nothing, and a crash after publication but before commit must re-observe
and idempotently re-publish the exact retained stage.

`StageEpochRotation` is enabled only at sequence exhaustion. It stages a signed checkpoint in the
next epoch at sequence zero; `ReobserveStaged` and `PublishStaged` remain mandatory. When both epoch
and sequence domains are exhausted, no emission transition exists. Counters never wrap.

`Recover` reloads the bounded retained checkpoint set for every emitter. It is disabled when the
authority is unobservable and does not infer the local emitter anchor from peers. Consequently,
crashing every peer does not destroy the committed anchors or a pending exact assertion. A live
peer may separately supply `RepairFromSemanticCheckpoint` when an overwrite has moved beyond the
bounded replay suffix; that repair changes semantic replica state, never emitter continuity
authority.

### 1.2 Delta delivery

Each directed link carries at most one pending delta slot. `DeliverDelta` accepts that slot only
when it is the immediate same-epoch successor or the valid checkpoint transition to sequence zero
in the next epoch. `DiscardUnusableDelta` removes duplicates, delayed old epochs, and frames for a
different Orders anchor without changing semantic state.

A newer publication may overwrite an undelivered slot. The model does **not** pretend that this
gap is an applicable delta. `RepairFromSemanticCheckpoint` instead atomically represents the
runtime's bounded, signed, one-emitter checkpoint application; subsequent rounds deliver its
bounded replay suffix. The donor and receiver must share an active Orders version, and the repair
copies semantic kind as well as cursor position. TLC abstracts the concrete checkpoint bytes,
evidence signatures, and suffix frame into this fixed-cardinality action.

The runtime wire protocol additionally applies byte, assertion-count, parser-input, concurrent
in-flight, and rejection-summary bounds. TLC abstracts those numerical byte checks into the fixed
delta-slot shape; native property tests cover the actual encoders and admission functions.

### 1.3 Orders and DNS authority

`StageOrdersPromotion` owns one promotion slot. The initial active version is zero, so version one
is reachable in the checked configuration rather than being disabled by construction.
`CheckpointOrdersPromotion` replaces the active version, clears the slot, reloads matching-version
semantic checkpoints from retained authority, and evicts evidence from every older version.

`DnsWrite` requires all of the following in the same state:

- the local node is live and its owner projection selects itself
- its current semantic assertion is a claim
- its Orders version is active and no promotion is pending
- a credential generation is ready
- retained continuity is observable
- no retained staged assertion remains; the claim is committed

Credential loss, continuity loss, crash, ownership loss, and Orders promotion revoke the modelled
live DNS-writer lease.

---

## 2. Variable-to-runtime Correspondence

| TLA+ variable | Runtime correspondence |
|---|---|
| `activeOrders`, `promotionSlot` | opaque admitted Orders anchor plus the single bounded promotion slot |
| `latestEpoch`, `latestSequence`, `latestKind` | latest heartbeat/ownership semantic checkpoint keyed by admitted emitter; kind is part of semantic equality |
| `cursorEpoch`, `cursorSequence` | receive `CursorVector`, keyed by admitted emitter |
| `deltaPresent`, `deltaOrders`, `deltaEpoch`, `deltaSequence`, `deltaKind` | one bounded immediate-delta slot per directed link, including its Orders anchor and semantic kind |
| `authorityOrders`, `authorityEpoch`, `authoritySequence`, `authorityKind`, `authorityPhase` | retained `GatewayContinuityAuthority` committed checkpoint and idle/staged disposition |
| `stagedOrders`, `stagedEpoch`, `stagedSequence`, `stagedKind` | exact retained staged signed assertion and next-anchor record |
| `stageObserved`, `publishAcknowledged` | volatile process witnesses erased on crash; neither is retained continuity state |
| `continuityObservable` | successful retained-authority observation; missing/corrupt/unobservable observations fail closed |
| `credentialReady` | generation-tagged `DnsCredentialObservation` that can construct a sealed AWS environment |
| `ownerView` | constant-time cached owner projection used by readiness and DNS gating |
| `dnsWriteNode` | current, revocable DNS-write authority lease rather than historical write telemetry |
| `live` | running gateway process set in the multi-node fault model |

The runtime uses HMAC signatures, canonical encodings, byte limits, child-process permits, socket
deadlines, and structured errors. Those concrete mechanisms refine the abstract transitions; they
are validated by native tests rather than represented as cryptographic or byte-array state in TLC.

---

## 3. TLC Domains and Production Bounds

The checked configuration is:

| Constant | TLC value | Meaning |
|---|---:|---|
| `Nodes` | `{n1, n2}` | smallest ranked multi-node topology that exercises concurrent emitters, crash/recovery, and delivery reordering |
| `MaxEpoch` | `1` | exercises one durable epoch rotation |
| `MaxSequence` | `1` | exercises ordinary publication followed by rotation |
| `MaxOrdersVersion` | `1` | finite Orders-version domain; initialization at zero makes the promotion to one reachable |

The two-node configuration is an exhaustive protocol-state check, not a deployment-size claim.
Production membership is bounded by admitted Orders and native capacity validation. The home
substrate runs three logical ranked peers on one physical host. It exercises multi-peer protocol
behavior, but all three peers share the host's failure fate and therefore cannot prove resilience
to an independent-host network partition. AWS and future multi-host deployments exercise that
separate physical-fault axis.

### 3.1 Finite model domains are not runtime bounds

The checked configuration uses no TLC `CONSTRAINT` or `StateConstraint`. Finite model domains make
exhaustive exploration possible, but they do not bound a list, map, frame, heap, or production
uptime. Production cardinality correspondence is instead explicit in `TypeOK`: every semantic and
cursor value is a total function over the admitted finite `Nodes` domain, every directed link has
one scalar delta slot, each emitter has at most one retained stage, and checkpoint repair handles
one emitter at a time. A future tractability-only constraint must be documented as an exploration
restriction and may never be cited as implementation or memory evidence.

Runtime memory is governed separately by:

1. validated raw Orders/member/field limits
2. bounded semantic, replay, diagnostic, parser, rejection, and in-flight structures
3. Sprint 1.60's retained-heap, scratch, native, child-peak, kernel, and safety-margin equation
4. the external runtime-stability oracle owned by Sprint 5.16

Passing TLC cannot substitute for any of those checks.

---

## 4. Checked Invariants

| Invariant | Meaning |
|---|---|
| `TypeOK` | Every variable stays inside its finite semantic domain. |
| `SemanticPositionMatchesCursor` | Every retained semantic checkpoint position equals its receive cursor, including crash-cleared sentinels. |
| `DeltaSlotsCanonical` | A free directed-link slot contains only sentinels; delivered or discarded frame payloads are cleared instead of becoming hidden historical state. |
| `EqualCursorAndOrdersDetermineSemantic` | Within one Orders version, equal per-emitter cursors imply equal retained position **and semantic kind**. Orders promotion is deliberately outside an older version's equality class. |
| `NoCursorAheadOfDurableAuthority` | No receiver observes a position newer than the emitter's committed anchor or its one durable staged frontier. A published-before-commit cursor may equal the stage. |
| `StagedTransitionIsNonWrapping` | Every retained stage is either the next sequence in-place or a signed checkpoint from an exhausted sequence to sequence zero in the next non-exhausted epoch; volatile publication implies prior exact observation. |
| `DnsLeaseRequiresCompleteGate` | A live DNS lease continues to satisfy the complete ownership, Orders, credential, and idle committed-continuity gate. |
| `ClaimPrecedesWrite` | A live DNS writer's current local semantic assertion is a claim. |
| `NoSimultaneousDNSWriters` | When live nodes have recomputed the same ranked leader, at most one node satisfies the complete DNS gate. |

These are safety properties. Progress depends on scheduler, transport, retained-store, and
credential availability assumptions and is exercised separately through daemon-lifecycle and
integration tests.

---

## 5. Deliberate Abstractions

The model does not attempt to prove:

- HMAC or hash collision resistance
- canonical CBOR/Dhall encoder correctness
- exact UTF-8, `Content-Length`, frame-byte, or heap-byte accounting
- TCP partial reads, timeout implementation, or OS socket scheduling
- Vault, MinIO, or Route 53 service availability
- GHC residency, garbage-collector behaviour, kernel memory, or child-process RSS
- liveness during an unbounded asynchronous partition

Native unit tests cover bounds, signing/admission, stage/reobserve/publish/commit crash points,
delta and checkpoint-repair convergence, stale epochs, credential gates, and constant-time probe
source guards. Daemon-lifecycle tests cover the real listener, restart, and child scheduling
boundaries. Profiling and the Sprint 5.16 soak remain independent proof axes.

---

## 6. Partition Posture

The ranked rule cannot guarantee both unconditional autonomous failover and unconditional
single-writer safety in a fully asynchronous partition. The model therefore states
`NoSimultaneousDNSWriters` only for `FullyStable`, where every live node has recomputed the same
ranked leader. Outside that condition, the stronger production DNS gate still requires a current
claim, retained continuity fence, and credential generation, but it cannot manufacture consensus
from an unobservable network.

The home substrate's three logical peers can exercise directed peer communication and logical
partition handling, but their one physical host gives them a shared failure fate. The model checks
the multi-peer protocol independently of that placement; live AWS or a future multi-host substrate
is still required to exercise independent-host partition resilience.

---

## 7. Verification Result

Run:

```bash
prodbox dev tla-check
```

`src/Prodbox/Tla.hs` runs TLC 2.18 in the pinned `maxdiefenbach/tlaplus` container with eight
workers and records the result in `documents/engineering/tla/tlc_last_run.txt`.

The Sprint 2.31 configuration completed exhaustive exploration with no invariant violation:

- 606,637,449 states generated
- 51,491,308 distinct states checked
- depth 44
- zero states left on the queue

This result covers the finite model and the nine invariants above. It makes no claim about states
excluded by the documented domains or about the concrete runtime mechanisms listed in §5.

---

## Cross-References

- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [TLA+ model](./tla/gateway_orders_rule.tla)
- [TLA+ configuration](./tla/gateway_orders_rule.cfg)
- [Runtime memory doctrine](./resource_scaling_doctrine.md)
- [Development plan](../../DEVELOPMENT_PLAN/README.md)
