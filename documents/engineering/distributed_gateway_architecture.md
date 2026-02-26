# Distributed Gateway Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/README.md

> **Purpose**: Define the fully peer-to-peer prodbox architecture using shared Orders + append-only commit log with formally constrained gateway leadership rules.

---

## 1. Non-Negotiable Requirements

This design assumes:

1. No centralized coordinator (no DynamoDB, etc.).
2. All nodes use mutual TLS and are fully trusted peers.
3. A typed global Orders document exists (protobuf), with monotonic UTC version timestamp.
4. Nodes immediately promote newer validated Orders.
5. Every node maintains its own stable DNS record.
6. Only gateway owner updates primary gateway DNS record.
7. A global append-only event log is the source of truth and is recovered peer-to-peer.

---

## 2. Current Repo Gaps

Current implementation remains single-node oriented:

1. DNS DAG root is still a `FetchPublicIP` effect, not a multi-node leadership workflow.
2. Infra provisions one public A record, but no node set / orders / log semantics.
3. Runtime uses timer-driven DDNS, not peer leadership loop.

Source files:
- `src/prodbox/cli/dag_builders.py`
- `src/prodbox/infra/dns.py`
- `scripts/route53-ddns.service`
- `scripts/route53-ddns.timer`

---

## 3. Architecture Overview

## 3.1 Orders Plane (Control Intent)

`Orders` protobuf is the declarative configuration object:

- `orders_version_utc` (int64, strictly increasing)
- `orders_hash`
- `nodes[]` (node_id, stable_fqdn, rank)
- `gateway_rule` (schema-constrained rule)
- `rule_parameters` (timeouts, windows, jitter, etc.)

Nodes validate signature + schema + monotonic timestamp before promotion.

## 3.2 Event Plane (Source of Truth)

Global append-only commit log events:

- Hash chained (`prev_hash`, `event_hash`)
- Signed by emitter
- Includes `emitter_node_id`, `event_ts_utc`, payload protobuf

Event classes:

- `OrdersPublished`
- `NodeHeartbeat`
- `GatewayClaim`
- `GatewayYield`
- domain events

Replication is anti-entropy gossip over stable node DNS names.

## 3.3 DNS Plane

1. Per-node record: `node-k.prodbox.resolvefintech.com`
2. Gateway record: `prodbox.resolvefintech.com`

All nodes own their node record updates.
Only elected gateway owner updates gateway record.

---

## 4. Gateway Rule Model

## 4.1 Safe-by-Construction Rule Schema

Only rule families with machine-checkable invariants are allowed.
Initial allowed family:

- `RankedFailoverRule` with deterministic total order over nodes.

Inputs:

- ordered node ranks from Orders
- heartbeat freshness from commit log
- rule timeouts

Output:

- exactly one `intended_gateway_owner` for a given state snapshot

Tie-break is fixed: `(rank, node_id)` lexicographic.

## 4.2 Required Failsafe

Rule schema must enforce:

- If a node has no fresh heartbeat from peers for `isolation_timeout`, it must become self-candidate.

This satisfies the “all others down” takeover requirement.

---

## 5. Safety Boundary (Important)

In a fully asynchronous system, with partitions and no consensus primitive, you cannot guarantee both:

1. absolute no-split-brain leadership safety, and
2. always-available autonomous failover.

This is a fundamental distributed systems limit.

Therefore the design contract is:

1. `NoTugOfWar` is proven for the modeled assumptions (bounded skew/delay or equivalent failure-detector assumptions in TLA+).
2. Under severe partition uncertainty, implementation must choose explicit mode:
   - safety-first fail-closed, or
   - availability-first best effort.

The schema can forbid ambiguous rule forms, but cannot bypass impossibility results.

---

## 6. Rejoin + Eventual Consistency

When a silent node returns:

1. It reconnects via stable node DNS.
2. It performs anti-entropy pull of missing log segments.
3. It validates hash chain and schemas.
4. It promotes latest Orders by UTC version.
5. It recomputes gateway candidacy and either:
   - yields immediately, or
   - starts/continues gateway ownership actions if selected.

This provides deterministic convergence.

---

## 7. P2P Protocol Requirements

## 7.1 Transport

- Mutual TLS for all peer RPCs.
- Node identity bound to cert subject + Orders node_id mapping.

## 7.2 Log Replication

- Range pull by `(from_event_hash | from_index)`.
- Merkle/hash frontier exchange for efficient diff.
- Idempotent append.

## 7.3 Corruption Resistance

- Per-event schema validation.
- Hash-chain integrity check.
- Signature verification.
- Reject-on-invalid, never partially apply.

---

## 8. TLA+ Scope

TLA+ model must cover:

1. `UniqueOwner`: at most one intended gateway owner per modeled state.
2. `DeterministicRule`: same Orders + same observed state => same owner.
3. `RejoinConvergence`: after gossip convergence, owners converge.
4. `SingletonTakeover`: if one node remains alive, it eventually self-elects.

Model files:

- `documents/engineering/tla/gateway_orders_rule.tla`
- `documents/engineering/tla/gateway_orders_rule.cfg`

Execution requirement:

- TLA+ checks must run via Docker using `tlaplatform/tlaplus`.
- Use the Poetry entrypoint `poetry run prodbox-tla-check`.
- The command runs a self-deleting container (`docker run --rm ...`) and writes the latest result to `documents/engineering/tla/tlc_last_run.txt`.

---

## 9. Implementation Plan

## Phase 1

1. Add Orders + log protobuf schemas.
2. Add node identity settings and stable DNS settings.
3. Add per-node DNS reconcile command.

## Phase 2

1. Add peer gossip service (mTLS) for log anti-entropy.
2. Add gateway rule evaluator from active Orders + log-derived health.
3. Add `prodbox-gateway-loop` daemon command (`poetry run prodbox-gateway-loop --config ...`).

## Phase 3

1. Gate gateway DNS writes behind rule-elected ownership.
2. Emit `GatewayClaim` / `GatewayYield` events.
3. Add rejoin reconciliation path and tests.

## Phase 4

1. Expand TLA+ model for message delay, crash, recovery.
2. Validate invariants and liveness assumptions.
3. Add failure-injection integration tests.

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Documentation Standards](../documentation_standards.md)
