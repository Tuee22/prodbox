# Distributed Gateway Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/local_registry_pipeline.md, documents/engineering/tla_modelling_assumptions.md

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

## 2. Planning Ownership

This document owns gateway architecture doctrine only.

Clean-room sequencing, completion status, remaining work, and legacy-path
removal for gateway delivery are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

Canonical repository facts referenced by this doctrine:

1. The current mixed gateway implementation is split between native `src/Prodbox/Gateway.hs`
   for `prodbox gateway status|config-gen` and retained `src/prodbox/gateway_daemon.py` plus
   `src/prodbox/cli/gateway.py` for the running daemon and `prodbox gateway start`.
2. The managed CLI surface remains `prodbox gateway start|status|config-gen`.
3. Verification artifacts include `tests/unit/test_gateway_daemon.py`,
   `tests/integration/test_gateway_daemon_k8s.py`,
   `tests/integration/test_gateway_k8s_pods.py`, and
   `documents/engineering/tla/gateway_orders_rule.tla`.

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

- TLA+ checks must run via Docker using `maxdiefenbach/tlaplus`.
- On the current mixed baseline, `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` entrypoint.
- Use the CLI command `prodbox tla-check`.
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
```

When `dns_write_gate` is `None`, the daemon leaves Route 53 writes disabled.

### Route53DnsWriteClient

Implements the `DnsWriteClient` protocol:
- `fetch_public_ip()` — via `checkip.amazonaws.com`
- `update_route53_record()` — boto3 UPSERT A record wrapped with `asyncio.to_thread()`
- Auto-wired in daemon startup when gate config is present and no mock injected

AWS auth for gateway DNS writes is loaded from `Settings` via the repo-root
`prodbox-config.json` compiled from `prodbox-config.dhall`.
`dns_write_gate` must not contain AWS access key, secret key, session token, or similar
credential fields.

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
    "has_active_claim": true,
    "event_count": 42,
    "event_hashes": ["abc123", "def456"],
    "mesh_peers": ["node-b", "node-c"],
    "last_public_ip_observed": "203.0.113.10",
    "last_dns_write_ip": "203.0.113.10",
    "last_dns_write_at_utc": "2026-04-06T12:00:00Z",
    "dns_write_gate": {
        "zone_id": "Z1234567890",
        "fqdn": "gw.example.test",
        "ttl": 60,
        "aws_region": "us-east-1"
    }
}
```

Used by integration tests for observability and by `prodbox gateway status` CLI.

---

## 12. Deployment Model

The canonical steady state for the gateway daemon is the in-cluster
`prodbox charts deploy gateway` workload. The chart at `charts/gateway/` renders
one Deployment per ranked node id, each backed by a per-node `gateway-<id>`
Service, an orders ConfigMap, a per-node config ConfigMap, a cert-manager-issued
TLS material set, and a Kubernetes Secret carrying the prodbox-config.json that
the daemon's Route 53 client reads at runtime.

On the current mixed baseline, `prodbox gateway start <config.json>` is still
served by the retained Python daemon path and remains the in-pod entrypoint
invoked by the gateway chart's container. Native Haskell `prodbox gateway
status <config.json>` and `prodbox gateway config-gen <path> --node-id <id>`
now cover operator status inspection and config-template generation. The
`gateway start` path is also the dev-only mode used when running the daemon
directly against a host process for local iteration; that mode is not a
supported public-host steady state and no host-side supervisor is installed.

Containerization is first-class for integration/runtime image publishing:

- `prodbox rke2 install` builds the gateway image from `docker/gateway.Dockerfile`
- the image is pushed to local Harbor and imported into local RKE2 containerd cache
- Kubernetes pod integration tests run against that image by default
- `PRODBOX_GATEWAY_IMAGE` remains an override for explicit image pinning/testing

See [Local Registry Pipeline](./local_registry_pipeline.md) for Harbor install,
Docker build/push flow, and RKE2 mirror behavior.

### CLI Management

```bash
prodbox gateway start <config.json>           # In-pod daemon entrypoint
prodbox gateway status <config.json>          # Query running daemon
prodbox gateway config-gen <path> --node-id <id>  # Generate template config
prodbox charts deploy gateway                 # Install/upgrade in-cluster gateway workload
prodbox charts status gateway                 # Inspect installed gateway release
```

---

## 13. Verification Surfaces

Gateway verification lives in four canonical places:

1. `tests/unit/test_gateway_daemon.py` for daemon logic and DNS-write gating.
2. `tests/integration/test_gateway_daemon_k8s.py` for process-mode mesh behavior.
3. `tests/integration/test_gateway_k8s_pods.py` for pod-backed mesh behavior.
4. `prodbox tla-check` plus `documents/engineering/tla/gateway_orders_rule.tla`
   for formal safety checks.

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
