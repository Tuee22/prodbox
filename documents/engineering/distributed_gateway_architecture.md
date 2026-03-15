# Distributed Gateway Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, README.md

> **Purpose**: Define the fully peer-to-peer prodbox architecture using shared Orders + append-only commit log with formally constrained gateway leadership rules.

---

## 0. Canonical Doctrine Statements

Partition semantics for gateway leadership and DNS write gating must be formally verified by TLA+ before implementation changes are accepted.

For this Byzantine-generals-class failure mode, TLA+ model checking is the primary completeness tool; runtime tests validate model-to-code fidelity but are not exhaustive proofs.

Gateway timing contract is explicit: heartbeat_timeout_seconds in [3, 60], isolation_timeout_seconds = heartbeat_timeout_seconds, heartbeat_interval_seconds <= timeout/2, reconnect_interval_seconds <= timeout, and sync_interval_seconds <= timeout*2.

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

## 2. Implementation Status

The distributed gateway system is fully implemented (Phases 1-8 complete):

- **Gateway daemon**: `src/prodbox/gateway_daemon.py` (1387 lines)
- **CLI management**: `src/prodbox/cli/gateway.py` (`start`, `status`, `config-gen`)
- **TLA+ models**: `documents/engineering/tla/gateway_orders_rule.tla`
- **Unit tests**: 54 gateway daemon tests in `tests/unit/test_gateway_daemon.py`
- **Integration tests**: `tests/integration/test_gateway_k8s_pods.py` (K8s pod deployment)

The daemon runs as a local Python process via `poetry run daemon`. DDNS timer fallback (`scripts/`) remains for single-node operation.

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
- Use the CLI command `poetry run prodbox tla-check`.
- The command runs a self-deleting container (`docker run --rm ...`) and writes the latest result to `documents/engineering/tla/tlc_last_run.txt`.

For modelling assumptions, variable correspondence, known divergences, and verification status, see [TLA+ Modelling Assumptions](./tla_modelling_assumptions.md).

---

## 9. GatewayClaim / GatewayYield Event Lifecycle

Ownership transitions are tracked via typed events in the commit log:

| Event | Trigger | Payload |
|-------|---------|---------|
| `GatewayClaim` | This node becomes elected gateway owner | `{"claiming_node_id": str, "previous_owner": str \| None}` |
| `GatewayYield` | This node loses gateway ownership | `{"yielding_node_id": str, "new_owner": str}` |

**Ordering guarantee**: `GatewayYield` from the old owner is emitted before `GatewayClaim` from the new owner when transitions occur within the same node's recomputation cycle.

---

## 10. DNS Write Gating

Only the elected gateway owner writes the primary DNS A record. Two conditions must be satisfied:

1. **Ownership check**: `gateway_owner == self.node_id`
2. **Claim check**: A `GatewayClaim` event from self exists in the local commit log

This prevents stale writes from lagging nodes that haven't yet learned about ownership changes.

### DnsWriteGate Configuration

```python
@dataclass(frozen=True)
class DnsWriteGate:
    zone_id: str        # Route 53 hosted zone ID
    fqdn: str           # Gateway FQDN to update
    ttl: int            # DNS record TTL (seconds)
    aws_region: str
    aws_access_key_id: str
    aws_secret_access_key: str
```

When `dns_write_gate` is `None`, DNS write loop is a no-op (backward compatible).

### Route53DnsWriteClient

Implements the `DnsWriteClient` protocol:
- `fetch_public_ip()` — via `checkip.amazonaws.com`
- `update_route53_record()` — boto3 UPSERT A record wrapped with `asyncio.to_thread()`
- Auto-wired in daemon startup when gate config is present and no mock injected

---

## 11. REST API

### `POST /v1/handshake`

Peer connection establishment with CN verification against expected peer node IDs.

### `GET /v1/state`

Returns current daemon state:

```json
{
    "node_id": "node-a",
    "gateway_owner": "node-a",
    "event_count": 42,
    "event_hashes": ["abc123", "def456"],
    "mesh_peers": ["node-b", "node-c"]
}
```

Used by integration tests for observability and by `prodbox gateway status` CLI.

---

## 12. Deployment Model

The default operator path runs the gateway daemon as a **local Python process** via
`poetry run daemon --config <path>`.

Containerization is also first-class for integration/runtime image publishing:

- `prodbox rke2 ensure` builds the gateway image from `docker/gateway.Dockerfile`
- the image is pushed to local Harbor and imported into local RKE2 containerd cache
- Kubernetes pod integration tests run against that image by default
- `PRODBOX_GATEWAY_IMAGE` remains an override for explicit image pinning/testing

See [Local Registry Pipeline](./local_registry_pipeline.md) for Harbor install,
Docker build/push flow, and RKE2 mirror behavior.

### CLI Management

```bash
prodbox gateway start <config.json>           # Run gateway event loop
prodbox gateway status <config.json>          # Query running daemon
prodbox gateway config-gen <path> --node-id <id>  # Generate template config
```

---

## 13. Implementation History

All phases complete:

| Phase | Deliverable |
|-------|-------------|
| **1** | Orders + CommitLog schemas, node identity, stable DNS settings |
| **2** | mTLS peer gossip, gateway rule evaluator, `daemon` daemon |
| **3** | GatewayClaim/GatewayYield typed events |
| **4** | DNS write gating with claim requirement |
| **5** | K8s pod infrastructure (manifests, fixtures, helpers) |
| **6** | K8s pod integration tests (mesh, failover, partition, DNS) |
| **7** | TLA+ model extension (bounded timestamps, claim/yield invariants) |
| **8** | Gateway hardening (REST API, Route53 client, CLI command group) |

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Documentation Standards](../documentation_standards.md)
