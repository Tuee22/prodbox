# Distributed Gateway Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/local_registry_pipeline.md, documents/engineering/tla_modelling_assumptions.md

> **Purpose**: Define the fully peer-to-peer prodbox architecture using shared Orders + append-only commit log with formally constrained gateway leadership rules.

---

## 0. Canonical Doctrine Statements

Partition semantics for gateway leadership and DNS write gating must be formally verified by TLA+ before implementation changes are accepted.

For this Byzantine-generals-class failure mode, TLA+ model checking is the primary completeness tool; runtime tests validate model-to-code fidelity but are not exhaustive proofs.

Gateway timing contract is explicit: heartbeat_timeout_seconds in [3, 60], isolation_timeout_seconds = heartbeat_timeout_seconds, heartbeat_interval_seconds <= timeout/2, reconnect_interval_seconds <= timeout, and sync_interval_seconds <= timeout*2.

This doctrine covers the Haskell distributed gateway daemon only. The Kubernetes Gateway API
public-edge controller target is owned separately by
[Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md).

---

## 1. Non-Negotiable Requirements

This design assumes:

1. No centralized coordinator (no DynamoDB, etc.).
2. All nodes are fully trusted mesh peers identified by Orders membership and per-node event
   keys; peer trust material remains part of the gateway config and chart contract.
3. A typed global Orders document exists (protobuf), with monotonic UTC version timestamp.
4. Nodes immediately promote newer validated Orders.
5. Every node has a stable peer endpoint in Orders for mesh communication.
6. Only gateway owner updates the canonical public DNS record `test.resolvefintech.com`.
7. A global append-only event log is the source of truth and is recovered peer-to-peer.

---

## 2. Planning Ownership

This document owns gateway architecture doctrine only.

Clean-room sequencing, completion status, remaining work, and legacy-path
removal for gateway delivery are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

This document defines the target gateway architecture and formal protocol contract.
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

`Orders` protobuf is the declarative configuration object:

- `orders_version_utc` (int64, strictly increasing)
- `orders_hash`
- `nodes[]` (node_id, stable peer endpoint fields, rank)
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

Replication is anti-entropy gossip over the stable peer endpoints carried in Orders.

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

1. It reconnects via the stable peer endpoint carried in Orders.
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

- Peer transport is a signed HTTP event-batch push on the configured
  peer-events port. `POST /v1/peer/events` is the peer batch ingest
  surface; `GET /v1/state` is the separate operator-facing observability
  surface.
- Certificate, key, CA, and socket fields remain part of the gateway
  config and chart trust-material contract for the peer mesh. The daemon
  validates the retained certificate, key, and CA files at startup and
  binds the REST plus peer-events listeners on the configured local
  Orders hosts before the signed peer mesh begins.
- Node identity is bound to the Orders `node_id` mapping: the receiver
  validates each event's HMAC signature against the per-node key in
  `daemonEventKeys`, refuses unknown emitters, and ignores events whose
  emitter id is outside the Orders node set.

## 7.2 Log Replication

- Each daemon periodically pushes its append-only commit log to every
  other peer over the events port.  The protocol is a simple
  `POST /v1/peer/events` carrying a JSON batch plus the sender's monotonic
  `orders_version_utc`.
- Acceptance is idempotent: the receiver merges through `appendIfNew`, so
  repeated pushes never create duplicates.
- The receiver updates its view of every other node's last heartbeat from
  the inbound event timestamps rather than from the local heartbeat loop
  alone, closing the documented gap between the runtime and the TLA+
  model's peer-communication assumptions.
- The receiver also tracks per-peer transport health
  (last inbound event timestamp, connect state, last error) and exposes
  it on `/v1/state` as `peer_transport`.

### 7.2.1 At-Least-Once Correspondence

`src/Prodbox/Daemon/Events.hs` is the canonical at-least-once helper for durable daemon event
consumers that need `processed_at` tracking, idempotent handlers, and replay from a persistent
store. The gateway peer mesh deliberately keeps its signed commit log as an in-memory
anti-entropy gossip log rather than adopting that durable store shape directly: peers exchange
complete signed batches, merge through `appendIfNew`, and derive heartbeat, transport-health, and
ownership state from the unique event set. That variant remains doctrine-compatible for the peer
gossip path because delivery idempotence is keyed by signed event hash and there is no separate
acknowledged work queue to mark processed.

Future daemon consumers that pull work from a durable queue or table use `Prodbox.Daemon.Events`;
the gateway only shares the idempotency rule and event-ordering discipline.

## 7.3 Corruption Resistance

- Per-event schema validation.
- Hash-chain integrity check.
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

## 7.5 Orders Promotion

- Orders carries the existing monotonic `version_utc` field.  Each peer
  push includes the sender's current `orders_version_utc`, and the
  receiver returns `409 Conflict` when the sender's view is older than
  the receiver's.  This prevents a stale peer from pushing events that
  predate the receiver's promotion of a newer Orders document.
- The daemon tracks the highest observed Orders version on
  `/v1/state` as `latest_observed_orders_version_utc`.  When the peer
  view advances past the local Orders, the daemon refuses to claim
  ownership until its local Orders catches up so a daemon rebooting
  against a stale Orders version cannot reclaim DNS write authority.

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
- `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` entrypoint.
- Use the CLI command `prodbox tla-check`.
- The command runs a self-deleting container (`docker run --rm ...`) and writes the latest result to `documents/engineering/tla/tlc_last_run.txt`.

For modelling assumptions, variable correspondence, known divergences, and verification status, see [TLA+ Modelling Assumptions](./tla_modelling_assumptions.md).

---

## 9. GatewayClaim / GatewayYield Event Lifecycle

Ownership transitions are tracked via typed events in the commit log,
emitted by the running daemon:

| Event | Trigger | Payload |
|-------|---------|---------|
| `claim` | This node becomes elected gateway owner | `{"claiming_node_id": str, "previous_owner": str \| None}` |
| `yield` | This node loses gateway ownership | `{"yielding_node_id": str, "new_owner": str \| None}` |

**Ordering guarantee**: A `yield` from the old owner is emitted before a
`claim` from the new owner when both transitions land in the same
recomputation cycle. The daemon keeps `statePreviousOwner` to detect
the transition and signs the resulting event with the local node's
configured event key before appending it to the commit log.

---

## 10. DNS Write Gating

Only the elected gateway owner writes the primary DNS A record. Two conditions must be satisfied
in the runtime, materialising the modelled `CanWriteDns` predicate:

1. **Ownership check**: `gateway_owner == self.node_id`
2. **Claim check**: the most recent claim/yield event from `self.node_id`
   in the commit log is a `claim`, not a `yield`.

The runtime helper `canWriteDns` enforces both conditions before
`dnsWriteLoop` issues a Route 53 UPSERT.  Because the commit log is
replicated through anti-entropy gossip (see Section 7), a stale owner
that has yielded cannot reclaim DNS write authority without first
observing a fresh `claim` from itself superseding its own `yield`.

The daemon emits a signed `claim` event on the non-owner-to-owner
transition and a signed `yield` event on the owner-to-non-owner
transition, so `ClaimPrecedesWrite` and `YieldPrecedesReclaim` from the
TLA+ spec hold on the runtime event log, not only on the model.

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

The committed Dhall `types` / `defaults` file split remains an active Sprint 2.11 closure item;
operators should treat the current structured JSON template as the implemented gateway-daemon
runtime shape, not as the final prescribed Dhall layout.

### Structured Logging

The gateway daemon and public workload daemon entrypoints emit structured JSON log lines to
stderr through `src/Prodbox/Gateway/Logging.hs`, backed by `co-log`. Log sites pass typed fields
through `field`; daemon-path lint rejects inline log-object construction in log calls.

Gateway log filtering reads `envLiveConfig` at each log site. The configured log level is seeded
from launch/config precedence at startup and subsequent `SIGHUP` reloads update the live log
threshold for later log calls without restart. The `prodbox-daemon-lifecycle` stanza verifies the
stderr JSON envelope and the hot-reload log-level path.

### Route53DnsWriteClient

The Haskell daemon wires DNS writes through native subprocess helpers:
- `fetchPublicIp()` invokes `curl -s --max-time 10 https://api.ipify.org`
- `writeDnsRecord()` invokes `aws route53 change-resource-record-sets` with an UPSERT batch
- The helpers are auto-wired during daemon startup when gate config is present and no mock is injected
- `docker/gateway.Dockerfile` installs the official AWS CLI bundle per target architecture so the
  Route 53 subprocess path remains available inside the runtime image
- `charts/gateway/` injects AWS credentials through the `gateway-aws-credentials` secret as
  environment variables rather than writing credentials into the daemon config

AWS auth for gateway DNS writes is derived from the repository-root Dhall configuration and the
runtime environment selected for the gateway workload.
`dns_write_gate` must not contain AWS access key, secret key, session token, or similar
credential fields.

---

## 11. REST API

### `POST /v1/peer/events`

Peer event-batch ingest over the configured peer-events port. The batch includes signed events
plus the sender's monotonic `orders_version_utc` view, and the receiver responds with explicit
accept or reject dispositions.

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
    "event_count": 42,
    "event_hashes": ["abc123", "def456"],
    "mesh_peers": ["node-b", "node-c"],
    "last_public_ip_observed": "203.0.113.10",
    "last_dns_write_ip": "203.0.113.10",
    "last_dns_write_at_utc": "2026-04-06T12:00:00Z",
    "heartbeat_age_seconds": {
        "node-a": 0.2,
        "node-b": 1.3
    },
    "peer_transport": {
        "node-b": {
            "connected": true,
            "last_inbound_event_age_seconds": 0.7,
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

`event_count` is the full unique-event cardinality of the local commit log. `event_hashes` is a
bounded recent tail of that log (currently the 64 most recent event hashes) so `GET /v1/state`
remains small enough for chart probes, `kubectl port-forward` backed validation, and
`prodbox gateway status` on long-lived meshes.

The `/v1/state` observability endpoint is an operator-facing HTTP surface on the in-pod REST
port. It is separate from the peer-to-peer event-batch transport used for gateway mesh
communication. The REST handler consumes the inbound HTTP request before closing the socket so the
operator-facing response contract stays intact when queried through `kubectl port-forward`.

### `GET /healthz`, `GET /readyz`, and `GET /metrics`

The gateway REST listener also exposes daemon-health endpoints on the same in-pod REST port:

- `/healthz` returns `200 ok` once the process is alive.
- `/readyz` returns `200 ready` only after the daemon enters `serve`; after SIGTERM or SIGINT it
  returns `503 draining` during the bounded drain window.
- `/metrics` emits Prometheus exposition text from `envMetrics`, including the gateway event
  counter and peer/heartbeat gauges.

Filesystem readiness markers and `sd_notify` are not supported readiness signals. The
`prodbox-daemon-lifecycle` Cabal stanza starts the real `prodbox gateway start` process, waits on
`/readyz` through the shared retry helper, observes drain readiness after SIGTERM, and asserts
exit `0` after the configured drain deadline or a second SIGTERM. The style suite rejects direct
`threadDelay` and raw `terminateProcess` use in that lifecycle stanza. The same stanza captures
stable `/healthz`, ready/draining
`/readyz`, and normalized `/metrics` response-shape goldens under `test/golden/daemon-health/`.

---

## 12. Deployment Model

The canonical steady state for the gateway daemon is the in-cluster
`prodbox charts deploy gateway` workload. The chart at `charts/gateway/` renders
one Deployment per ranked node id, each backed by a per-node `gateway-<id>`
Service, an orders ConfigMap, a per-node config ConfigMap, a cert-manager-issued
TLS material set, and the secret or config inputs required by the daemon at runtime.
The chart's liveness and readiness probes should query the health endpoints over HTTP on the
in-pod REST port; `/v1/state` remains the operator-facing state surface consumed by
`prodbox gateway status`.

`prodbox gateway start --config <path>` is the Haskell daemon entrypoint and remains the in-pod
startup path invoked by the gateway chart's container. `prodbox gateway status --config <path>`
queries that same HTTP `/v1/state` endpoint for operator inspection, and
`prodbox gateway config-gen <path> --node-id <id>` provides template generation. Direct
host-process invocation remains a development mode, not the supported steady state.

Containerization is first-class for integration/runtime image publishing:

- `prodbox rke2 reconcile` builds the gateway image from `docker/gateway.Dockerfile`
- the publish path runs an ordinary host-native `docker build`, then pushes the resulting Harbor
  tags from the repo-owned single-stage `ubuntu:24.04` Dockerfile with in-image `ghcup` and
  pinned GHC `9.14.1`
- Harbor is the supported source for the gateway workload image, and the host-arch variant is
  pulled back into local Docker before import into the RKE2 containerd cache
- Kubernetes pod integration tests run against that Harbor-published image by default
- `PRODBOX_GATEWAY_IMAGE` remains an override for explicit image pinning/testing

See [Local Registry Pipeline](./local_registry_pipeline.md) for Harbor install,
native-host-architecture publish flow, explicit public-image reconcile, and RKE2 registry behavior.

### CLI Management

```bash
prodbox gateway start --config <path>         # In-pod daemon entrypoint
prodbox gateway status --config <path>        # Query running daemon
prodbox gateway config-gen <path> --node-id <id>  # Generate template config
prodbox charts deploy gateway                 # Install/upgrade in-cluster gateway workload
prodbox charts status gateway                 # Inspect installed gateway release
```

---

## 13. Verification Surfaces

Gateway verification lives in four canonical places:

1. `test/unit/Main.hs` for daemon logic, rendering, and DNS-write gating support behavior.
2. `test/daemon-lifecycle/Main.hs` for process-level startup, readiness, signal drain, and
   daemon flag/env precedence coverage.
3. `prodbox test integration gateway-daemon` for daemon-oriented validation.
4. `prodbox test integration gateway-pods` for pod-backed mesh validation.
5. `prodbox tla-check` plus `documents/engineering/tla/gateway_orders_rule.tla`
   for formal safety checks.

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
