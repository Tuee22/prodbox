# Prodbox Project Plan

**Status**: Authoritative source
**Supersedes**: HOME_SERVER_CONFIG_PULUMI.md (original Terraform-to-Pulumi migration plan)
**Referenced by**: README.md

> **Purpose**: Comprehensive project plan covering architecture, implementation status, and detailed roadmap for the distributed gateway system.

---

## 1. Project Goals

Prodbox manages a home Kubernetes cluster with a distributed gateway daemon for DNS failover:

- **Python-native CLI** (Click) with a pure functional effect system
- **Infrastructure-as-code** via Pulumi (Python)
- **Distributed gateway daemon** with mTLS peer mesh and deterministic leadership election
- **Declarative, idempotent commands** for all operations
- **Components**: RKE2, MetalLB, Traefik, cert-manager, Route 53 DDNS

Target platform: Ubuntu 24.04 with RKE2 pre-installed.

---

## 2. Architecture Overview

### Network Design

```
Internet --> Router (80/443 port-forward) --> MetalLB IP --> Traefik --> Services --> Pods
                                                                 |
                                                           cert-manager
                                                           (TLS certs)
```

- **Node IP**: Server's LAN IP (e.g., `192.168.1.10`)
- **MetalLB Pool**: Dedicated IPs for LoadBalancer services (e.g., `192.168.1.240-192.168.1.250`)
- **Ingress LB IP**: Reserved IP for Traefik (e.g., `192.168.1.240`)

Router port forwarding:
- WAN:80 --> MetalLB IP:80
- WAN:443 --> MetalLB IP:443
- WAN:44444 --> Node IP:22 (SSH)

Forwarding to the MetalLB IP (not node IP) ensures host services cannot be reached from WAN on 80/443.

### Component Interaction

1. **MetalLB** advertises the ingress IP via Layer 2 ARP
2. **Traefik** binds to the MetalLB-assigned IP as a LoadBalancer service
3. **cert-manager** obtains TLS certificates via DNS-01 validation against Route 53
4. **Route 53** holds the A record; the gateway daemon (or DDNS timer fallback) updates it
5. **Pulumi** manages Kubernetes resources and Route 53 record existence
6. **Gateway daemon** elects a single owner to perform DNS writes via peer consensus

---

## 3. CLI Architecture

### Effect-Based Command System

All CLI operations follow a pure functional pipeline:

```
Click Command --> Smart Constructor --> DAG Builder --> Interpreter
   (thin)         Result[Cmd, E]       EffectDAG       (impurity)
```

1. **Smart constructors** validate inputs and return `Result[Command, str]`
2. **DAG builders** transform Commands into `EffectDAG` (pure, no I/O)
3. **Prerequisite expansion** resolves transitive dependencies via the registry
4. **Interpreter** executes effects (sole impurity boundary)

### Command Groups

7 command groups with 28+ commands:

| Group | Commands | Purpose |
|-------|----------|---------|
| `env` | `show`, `validate`, `template` | Configuration management |
| `host` | `ensure-tools`, `check-ports`, `info`, `firewall` | Host prerequisites |
| `rke2` | `status`, `ensure`, `start`, `stop`, `restart`, `logs` | RKE2 lifecycle |
| `pulumi` | `up`, `destroy`, `preview`, `refresh`, `stack-init` | Infrastructure |
| `dns` | `check`, `update`, `ensure-timer` | DNS and DDNS |
| `k8s` | `health`, `wait`, `logs` | Cluster health |
| `gateway` | `start`, `status`, `config-gen` | Gateway daemon management |

### Entry Points

Defined in `pyproject.toml`:
- `prodbox` --> `prodbox.cli.main:main` (primary CLI)
- `prodbox-tla-check` --> `prodbox.tla_check:main` (TLA+ model checker)
- `prodbox-gateway-loop` --> `prodbox.gateway_daemon:main` (gateway daemon)

---

## 4. Infrastructure Components

### MetalLB (v0.14.9)

Layer 2 LoadBalancer for bare-metal clusters. Deployed via Helm with:
- `IPAddressPool` CRD defining the LAN IP range
- `L2Advertisement` CRD for ARP-based IP announcement

### Traefik (v32.0.0)

Ingress controller with:
- `LoadBalancer` service type with specific IP from MetalLB
- HTTP (80) and HTTPS (443) entrypoints
- Prometheus metrics enabled

### cert-manager (v1.16.2)

Automatic TLS via Let's Encrypt DNS-01 validation:
- `ClusterIssuer` configured for Route 53
- AWS credentials stored as Kubernetes Secret
- No dependency on port 80 for ACME challenges

### Route 53

DNS management with two ownership modes:
- **Pulumi** owns record existence (clean teardown via `pulumi destroy`)
- **Gateway daemon** owns record value (elected owner updates A record)
- **DDNS timer** as fallback for single-node operation
- 60-second TTL for fast failover

### IAM Policy

Least-privilege: `route53:ChangeResourceRecordSets` scoped to the hosted zone, plus `route53:ListHostedZones` and `route53:ListResourceRecordSets`.

---

## 5. Distributed Gateway Architecture

> **SSoT**: [Distributed Gateway Architecture](documents/engineering/distributed_gateway_architecture.md)

### Design Principles

1. **No centralized coordinator** — fully peer-to-peer with mutual trust
2. **Typed Orders document** — monotonic UTC version, node set, gateway rule schema
3. **Append-only event log** — single source of truth, recovered via anti-entropy gossip
4. **Gateway DNS gating** — only elected owner updates the primary gateway A record
5. **Formally verified safety** — TLA+ models prove deterministic rule and no-tug-of-war invariants

### Three Planes

| Plane | Purpose | Content |
|-------|---------|---------|
| **Orders Plane** | Control intent | Nodes, ranks, rule parameters, `version_utc` |
| **Event Plane** | Source of truth | Signed events: `OrdersPublished`, `NodeHeartbeat`, `GatewayClaim`, `GatewayYield`, domain events |
| **DNS Plane** | User-facing | Per-node records (`node-k.prodbox.resolvefintech.com`) + gateway record (`prodbox.resolvefintech.com`) |

### Gateway Election: RankedFailoverRule

Deterministic total order over nodes: `(rank, node_id)` lexicographic tie-break.

Inputs: ordered node ranks from Orders, heartbeat freshness from commit log, rule timeouts.
Output: exactly one `intended_gateway_owner` for a given state snapshot.

**Failsafe**: Isolated node with no fresh peer heartbeats must become self-candidate (satisfies "all others down" takeover).

**Safety boundary**: Per FLP impossibility, the system cannot guarantee both absolute no-split-brain and always-available autonomous failover. Contract: `NoTugOfWar` proven for modeled assumptions; under severe partition, implementation chooses explicit mode (safety-first fail-closed or availability-first best-effort).

### Daemon Runtime

The `prodbox-gateway-loop` daemon (`src/prodbox/gateway_daemon.py`, 1387 lines) implements:

- **Dual-channel mTLS connections**: `mesh` (all-to-all gossip) + `gateway` (direct to elected owner)
- **HMAC-SHA256 signed, hash-chained CommitLog**: idempotent append, deterministic ordering
- **REST API**: `POST /v1/handshake` (peer CN verification), `GET /v1/state` (node_id, gateway_owner, event_count, event_hashes, mesh_peers)
- **Duplex event socket protocol**: `hello`, `event`, `sync_request`, `sync_response`
- **Background loops**: heartbeat, connection reconcile, anti-entropy sync, gateway recompute
- **Connection deduplication**: race-safe registry with lexicographic tie-breaking
- **Route53 DNS write client**: boto3-based A record upsert gated behind gateway ownership + GatewayClaim
- **CLI management**: `prodbox gateway start|status|config-gen` via effect DAG pipeline

### TLA+ Formal Verification

Model: `documents/engineering/tla/gateway_orders_rule.tla`

Specified invariants:
- `DeterministicRuleForEqualViews` — same Orders + same observations = same owner
- `NoTugOfWarWhenViewsConverged` — converged state has at most 1 gateway owner
- `NoSimultaneousDNSWriters` — at most 1 DNS writer when fully stable (FLP impossibility acknowledged for partitioned states)
- `ClaimPrecedesWrite` — DNS write requires prior claim
- `YieldPrecedesReclaim` — yield required between successive claims
- `SingletonSelfElection` — sole survivor's election function always picks itself (safety)

Execution: `poetry run prodbox-tla-check` (Docker-based TLC 2.18 model checker)

**Verification status**: All 6 safety invariants verified over 4,394,744 distinct states (HeartbeatTimeout=2, MaxTimestamp=2). See [TLA+ Modelling Assumptions](documents/engineering/tla_modelling_assumptions.md) for correspondence mapping, resolved divergences, and modelling bounds.

---

## 6. Implementation Status

### Complete

| Area | Detail |
|------|--------|
| **CLI** | 7 command groups, 28+ commands, full effect pipeline |
| **Effect system** | 47 effect types, DAG builder, interpreter |
| **Infrastructure** | All Pulumi modules: MetalLB, Traefik, cert-manager, ClusterIssuer, Route 53 |
| **Settings** | Pydantic configuration with environment variable validation |
| **Prerequisites** | Registry with transitive expansion |
| **Tests** | 746 tests (746 passing, 8 integration) |
| **Quality** | Zero ruff errors, zero mypy errors, ruff format clean |
| **DDNS** | Systemd timer units (`scripts/`) |
| **Gateway Phase 1** | Orders + CommitLog schemas, node identity, stable DNS settings |
| **Gateway Phase 2** | mTLS peer gossip, gateway rule evaluator, `prodbox-gateway-loop` daemon |
| **Gateway Phase 3** | GatewayClaim/GatewayYield typed events, ownership transition tracking |
| **Gateway Phase 4** | DNS write gating: only elected owner writes A record, requires GatewayClaim in log |
| **Gateway Phase 5** | K8s pod deployment infrastructure, manifest generators, test fixtures |
| **Gateway Phase 6** | K8s pod integration tests: mesh formation, failover, partition, DNS gating |
| **Gateway Phase 7** | TLA+ model extension: bounded timestamps, claim/yield, DNS write guard |
| **Gateway Phase 8** | `prodbox gateway` CLI command group: `start`, `status`, `config-gen` |
| **Gateway Hardening** | REST API extended (event_hashes, mesh_peers), config parsing, Route53DnsWriteClient |
| **TLA+** | Formal models proving deterministic rule + no-tug-of-war (3-node, bounded timestamps). TLC verified (6 safety invariants, 4.4M distinct states). See [TLA+ Modelling Assumptions](documents/engineering/tla_modelling_assumptions.md) |
| **CI/CD** | GitHub Actions CI, pre-commit hooks (ruff + mypy), Containerfile.gateway multi-stage build |
| **lib/ modules** | exceptions, subprocess, logging, async_runner, concurrency |
| **Docs** | All metadata compliant, cross-refs clean |

---

## 7. Project Structure

```
prodbox/
├── src/prodbox/
│   ├── cli/                          # Click CLI commands
│   │   ├── main.py                   # Entry point and command registration
│   │   ├── context.py                # Settings context for Click
│   │   ├── types.py                  # Result ADT, subprocess types
│   │   ├── effects.py                # 44 effect type definitions
│   │   ├── effect_dag.py             # DAG types and prerequisite expansion
│   │   ├── interpreter.py            # Effect interpreter (impurity boundary)
│   │   ├── dag_builders.py           # Pure Command-to-DAG transformations
│   │   ├── command_adt.py            # Command ADTs with smart constructors
│   │   ├── command_executor.py       # Single entry point for execution
│   │   ├── prerequisite_registry.py  # Prerequisite definitions
│   │   ├── env.py                    # Configuration commands
│   │   ├── host.py                   # Host prerequisite commands
│   │   ├── rke2.py                   # RKE2 management commands
│   │   ├── pulumi_cmd.py             # Pulumi commands
│   │   ├── dns.py                    # Route 53 DNS commands
│   │   ├── k8s.py                    # Kubernetes health commands
│   │   └── gateway.py                # Gateway daemon management commands
│   ├── infra/                        # Pulumi infrastructure definitions
│   │   ├── __main__.py               # Pulumi program orchestrator
│   │   ├── providers.py              # K8s and AWS providers
│   │   ├── metallb.py                # MetalLB deployment
│   │   ├── ingress.py                # Traefik ingress
│   │   ├── cert_manager.py           # cert-manager installation
│   │   ├── cluster_issuer.py         # ACME ClusterIssuer
│   │   └── dns.py                    # Route 53 DNS records
│   ├── lib/                          # Shared utilities
│   │   ├── exceptions.py             # ProdboxError, CommandError, TimeoutError
│   │   ├── subprocess.py             # Async subprocess runner (CommandResult)
│   │   ├── logging.py                # Rich console logging
│   │   ├── async_runner.py           # Click-asyncio bridge
│   │   └── concurrency.py            # Semaphore-based concurrency utilities
│   ├── gateway_daemon.py             # Distributed gateway daemon
│   ├── tla_check.py                  # TLA+ model checker (Docker-based)
│   └── settings.py                   # Pydantic configuration
├── tests/
│   ├── unit/                         # Unit tests (746 passing)
│   └── integration/                  # Cluster-dependent tests
│       ├── conftest.py               # Shared integration fixtures
│       ├── helpers.py                # Integration test helpers
│       ├── k8s_manifests.py          # Pure K8s manifest generators
│       ├── test_cli_commands.py      # CLI integration tests
│       ├── test_cli_env.py           # Env command integration tests
│       ├── test_gateway_daemon_k8s.py # Gateway mesh rejoin test (cert-manager PKI)
│       └── test_gateway_k8s_pods.py  # Gateway pod deployment + partition tests
├── typings/                          # Custom type stubs (Click, Pulumi, boto3, rich)
├── documents/                        # Engineering documentation
│   ├── documentation_standards.md
│   └── engineering/
│       ├── pure_fp_standards.md
│       ├── refactoring_patterns.md
│       ├── effectful_dag_architecture.md
│       ├── prerequisite_doctrine.md
│       ├── unit_testing_policy.md
│       ├── dependency_management.md
│       ├── distributed_gateway_architecture.md
│       └── tla/                      # TLA+ models and checker config
├── scripts/                          # Systemd units for DDNS
├── CLAUDE.md                         # AI assistant development guide
├── AGENTS.md                         # Agent guidelines
└── pyproject.toml                    # Poetry configuration
```

---

## 8. Distributed Gateway Roadmap

All gateway phases (1-8) are complete. The distributed gateway system is fully implemented with mTLS peer mesh, signed commit log, deterministic election, DNS write gating, K8s pod integration tests, TLA+ formal verification, and CLI management.

### Completed Phases Summary

| Phase | Goal | Status |
|-------|------|--------|
| **1** | Orders + CommitLog schemas, node identity, stable DNS settings | Complete |
| **2** | mTLS peer gossip, gateway rule evaluator, `prodbox-gateway-loop` daemon | Complete |
| **3** | GatewayClaim/GatewayYield typed ownership transition events | Complete |
| **4** | DNS write gating: only elected owner writes A record, requires GatewayClaim | Complete |
| **5** | K8s pod deployment infrastructure, manifest generators, test fixtures | Complete |
| **6** | K8s pod integration tests: mesh formation, failover, partition, DNS gating | Complete |
| **7** | TLA+ model extension: bounded timestamps, claim/yield, DNS write guard | Complete |
| **8** | Gateway hardening: REST API, Route53 client, `prodbox gateway` CLI | Complete |

### Phase 8: Gateway Hardening & CLI (Latest)

#### 8.1 REST API Extension

`GET /v1/state` now returns:
```json
{
    "node_id": "...",
    "gateway_owner": "...",
    "event_count": 42,
    "event_hashes": ["abc123", "def456", ...],
    "mesh_peers": ["node-b", "node-c"]
}
```

#### 8.2 Route53DnsWriteClient

Frozen dataclass implementing `DnsWriteClient` protocol:
- `from_gate(gate: DnsWriteGate)` — construct from config
- `fetch_public_ip()` — via `checkip.amazonaws.com`
- `update_route53_record()` — boto3 UPSERT A record via `asyncio.to_thread()`
- Auto-wired in `GatewayDaemon.__init__()` when `dns_write_gate` is set and no client injected

#### 8.3 `prodbox gateway` CLI Commands

| Command | Purpose |
|---------|---------|
| `prodbox gateway start <config>` | Load config and run gateway event loop |
| `prodbox gateway status <config>` | Query running daemon REST API |
| `prodbox gateway config-gen <path> --node-id <id>` | Generate template config JSON |

Full effect DAG pipeline: smart constructor → DAG builder → interpreter.

#### 8.4 Additional Hardening

- `DaemonConfig.from_json_file()` parses optional `dns_write_gate` JSON object
- TLA+ `MaxTimestamp` constant bounds `Nat` in `PromoteOrders`/`Tick` (finite state space)
- Unit test coverage: 54 gateway daemon tests (up from 24)

### Phase 3: GatewayClaim / GatewayYield Events

**Goal**: Replace the generic `gateway_owner_changed` event with typed ownership transition events that the commit log can reason about.

#### 3.1 Event Type Implementation

**File**: `src/prodbox/gateway_daemon.py`

Modify `_recompute_gateway_owner()` to emit typed events on ownership transitions:

| Event | Trigger | Payload |
|-------|---------|---------|
| `GatewayClaim` | `new_owner == self.node_id` (this node becomes gateway) | `{"claiming_node_id": str, "previous_owner": str \| None}` |
| `GatewayYield` | `self._gateway_owner == self.node_id` AND ownership moves away | `{"yielding_node_id": str, "new_owner": str}` |

Add validation in `_append_event_if_valid()` for `gateway_claim` and `gateway_yield` event types alongside existing `heartbeat` and `orders_published`.

#### 3.2 Unit Tests

**File**: `tests/unit/test_gateway_daemon.py`

| Test | Assertion |
|------|-----------|
| `test_gateway_claim_event_emitted_on_self_election` | Start daemon as highest rank, verify `GatewayClaim` in commit log |
| `test_gateway_yield_event_emitted_on_demotion` | Simulate ownership loss, verify `GatewayYield` in commit log |
| `test_claim_yield_pair_on_ownership_transition` | Verify correct ordering: yield from old owner precedes claim from new |
| `test_claim_event_contains_previous_owner` | Payload includes correct `previous_owner` field |
| `test_yield_event_contains_new_owner` | Payload includes correct `new_owner` field |

#### 3.3 Verification Gate

```bash
poetry run pytest -m "not integration"   # All unit tests pass
poetry run mypy src/                      # Zero errors
poetry run ruff check src/ tests/         # Zero errors
```

---

### Phase 4: DNS Write Gating

**Goal**: Only the elected gateway owner writes the primary DNS record. Writes require a `GatewayClaim` in the local commit log (prevents stale writes from lagging nodes).

#### 4.1 DnsWriteGate Configuration

**File**: `src/prodbox/gateway_daemon.py`

New frozen dataclass:

```python
@dataclass(frozen=True)
class DnsWriteGate:
    zone_id: str
    fqdn: str
    ttl: int
    aws_region: str
    aws_access_key_id: str
    aws_secret_access_key: str
```

Add optional `dns_write_gate: DnsWriteGate | None = None` to `DaemonConfig`.

#### 4.2 DNS Write Loop

New background loop `_dns_write_loop()`:

1. **Ownership check**: `_gateway_owner == self._config.node_id`
2. **Claim check**: `GatewayClaim` event from self exists in commit log
3. **Write**: If both conditions met, fetch public IP via httpx, update Route 53 via boto3
4. **Audit**: Emit `dns_write` event recording the write (IP, timestamp, zone_id)
5. **Interval**: Sleep for `dns_write_gate.ttl` seconds between writes

Guard: if `dns_write_gate is None`, the loop is a no-op (preserves backward compatibility with existing tests and configurations).

#### 4.3 Unit Tests

**File**: `tests/unit/test_gateway_daemon.py`

New test class `TestDnsWriteGating`:

| Test | Assertion |
|------|-----------|
| `test_dns_write_only_when_gateway_owner` | Mock boto3 client, verify writes only when node is elected owner |
| `test_dns_write_requires_claim_event_in_log` | No `GatewayClaim` in log = no DNS write |
| `test_dns_write_stops_after_yield` | After `GatewayYield`, DNS writes cease |
| `test_dns_write_gate_none_disables_loop` | No gate configured = loop does nothing |
| `test_dns_write_emits_audit_event` | Successful write emits `dns_write` event to commit log |

#### 4.4 Verification Gate

Same as Phase 3 gate.

---

### Phase 5: Kubernetes Pod Deployment Infrastructure

**Goal**: Build the container image and manifest generation infrastructure needed to deploy gateway daemons as real Kubernetes pods in the RKE2 cluster.

#### 5.1 Container Image

**File**: `Containerfile.gateway` (project root)

Multi-stage build for minimal runtime image:

```dockerfile
# --- Builder stage ---
FROM python:3.12-slim AS builder
RUN pip install --no-cache-dir poetry
WORKDIR /app
COPY pyproject.toml ./
RUN poetry config virtualenvs.in-project true \
    && poetry install --only main --no-interaction --no-ansi
COPY src/ src/
RUN poetry install --only main --no-interaction --no-ansi

# --- Runtime stage ---
FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/src /app/src
ENV PATH="/app/.venv/bin:$PATH"
ENTRYPOINT ["prodbox-gateway-loop"]
```

Build locally on the RKE2 node via `nerdctl build` or `ctr image import`. No registry push needed for single-node cluster.

#### 5.2 K8s Manifest Generators (Pure Functions)

**File**: `tests/integration/k8s_manifests.py`

Pure functions returning `dict[str, object]` manifests (serialized to YAML/JSON at call site):

| Function | Purpose |
|----------|---------|
| `gateway_namespace(name)` | Namespace for test isolation |
| `gateway_orders_configmap(namespace, orders)` | Orders document as ConfigMap |
| `gateway_daemon_pod(node_id, namespace, image, ports, cert_secret, ca_secret, ...)` | Gateway daemon pod spec |
| `gateway_service(node_id, namespace, rest_port, socket_port)` | ClusterIP service for each daemon |
| `gateway_network_policy_isolate(target_node, namespace)` | Deny all ingress/egress for labeled pod |
| `gateway_network_policy_allow_all(namespace)` | Remove isolation (delete policy) |

Pod spec details:
- TLS secrets from cert-manager mounted as volumes
- Orders ConfigMap mounted at `/etc/gateway/orders.json`
- Event keys passed as environment variables
- Pod labels: `app: prodbox-gateway`, `gateway-node: {node_id}`
- Liveness probe: `GET /v1/state` on REST port

#### 5.3 Test Infrastructure Fixtures

**File**: `tests/integration/conftest.py`

Refactor shared infrastructure from `test_gateway_daemon_k8s.py` into reusable fixtures:

**Session-scoped fixtures** (run once per test session):

| Fixture | Purpose |
|---------|---------|
| `kubeconfig` | Resolve kubeconfig path, skip if unavailable |
| `require_rke2_and_cert_manager` | Validate cluster reachable + cert-manager CRDs present |
| `gateway_image` | Build container image, skip if build tools unavailable |
| `gateway_namespace` | Create unique namespace, provision cert-manager certs, cleanup on teardown |

**Function-scoped fixtures** (run per test):

| Fixture | Purpose |
|---------|---------|
| `deploy_gateway_mesh(namespace, image, node_ids, orders)` | Deploy N daemon pods + services, wait for Running, return pod metadata |

**Shared helpers** moved to `tests/integration/helpers.py`:

| Helper | Purpose |
|--------|---------|
| `run_kubectl_capture_via_dag()` | kubectl execution via effect DAG |
| `wait_for_certificate()` | Wait for cert-manager Certificate Ready |
| `write_tls_material()` | Extract TLS files from K8s secrets |
| `wait_for_async()` | Async condition polling with timeout |

#### 5.4 Verification Gate

```bash
poetry run pytest -m "not integration"    # Unit tests still pass
poetry run pytest -m integration          # Existing integration test still passes
```

---

### Phase 6: K8s Pod Integration Tests

**Goal**: Deploy gateway daemons as Kubernetes pods and test distributed behavior with real network isolation, pod crashes, and DNS write gating.

**File**: `tests/integration/test_gateway_k8s_pods.py`

All tests marked `@pytest.mark.integration`, `@pytest.mark.e2e`, `@pytest.mark.slow`.

#### 6.1 Mesh Formation and Convergence

**`test_pods_form_mesh_and_converge_on_owner`**

| Step | Action |
|------|--------|
| 1 | Deploy 3 pods (node-a rank 1, node-b rank 2, node-c rank 3) |
| 2 | Wait for all pods Running |
| 3 | Poll `GET /v1/state` on each pod via `kubectl exec` |
| 4 | Assert all nodes agree `gateway_owner == "node-a"` (highest rank) |
| 5 | Verify `GatewayClaim` from node-a exists in all commit logs |

#### 6.2 Failover on Pod Crash

**`test_pod_crash_triggers_failover`**

| Step | Action |
|------|--------|
| 1 | Deploy 3 pods, wait for convergence on node-a |
| 2 | `kubectl delete pod node-a --grace-period=0` (simulate crash) |
| 3 | Wait `heartbeat_timeout_seconds` + buffer |
| 4 | Poll remaining pods: assert `gateway_owner == "node-b"` |
| 5 | Verify no `GatewayYield` (crash = no graceful yield) |
| 6 | Verify `GatewayClaim` from node-b in logs |

**`test_pod_restart_reclaims_ownership`**

| Step | Action |
|------|--------|
| 1 | From crashed state: K8s restarts node-a pod |
| 2 | Wait for pod Running + mesh reconnection |
| 3 | Wait for heartbeats to propagate |
| 4 | Assert all nodes converge back to `gateway_owner == "node-a"` |
| 5 | Verify `GatewayYield` from node-b + `GatewayClaim` from node-a |

#### 6.3 NetworkPolicy Partition Simulation

RKE2 ships with Canal CNI (Calico + Flannel) which enforces NetworkPolicy. All partition tests use NetworkPolicy to simulate network failures.

**`test_network_partition_causes_split_brain_then_heals`**

| Step | Action |
|------|--------|
| 1 | Deploy 3 pods, converge on node-a |
| 2 | Apply `gateway_network_policy_isolate("node-c")` — deny all ingress/egress for node-c |
| 3 | Wait for node-c's heartbeat timeout to expire for its peers |
| 4 | Assert: node-a + node-b see `gateway_owner == "node-a"` |
| 5 | Assert: node-c sees `gateway_owner == "node-c"` (failsafe self-election) |
| 6 | Delete NetworkPolicy (heal partition) |
| 7 | Wait for anti-entropy sync + heartbeat propagation |
| 8 | Assert all 3 pods converge on `gateway_owner == "node-a"` |

**`test_primary_isolation_triggers_failover_for_majority`**

| Step | Action |
|------|--------|
| 1 | Deploy 3 pods, converge on node-a |
| 2 | Isolate node-a via NetworkPolicy |
| 3 | node-b and node-c lose heartbeats from node-a |
| 4 | Assert node-b + node-c converge on `gateway_owner == "node-b"` |
| 5 | Assert node-a (isolated) self-elects: `gateway_owner == "node-a"` (stale) |
| 6 | Heal partition |
| 7 | Assert all reconverge on `gateway_owner == "node-a"` (highest rank, now reachable) |

#### 6.4 DNS Write Gating Under Partition

**`test_only_gateway_owner_writes_dns`**

| Step | Action |
|------|--------|
| 1 | Deploy 3 pods with `DnsWriteGate` configured (staging Route 53 zone or mock) |
| 2 | Wait for convergence on node-a |
| 3 | Verify only node-a has `dns_write` events in commit log |
| 4 | Kill node-a pod |
| 5 | Verify node-b claims gateway and begins DNS writes |
| 6 | Verify node-c never emits `dns_write` events (rank 3, never elected) |

#### 6.5 Event Log Consistency After Partition

**`test_event_log_converges_after_partition_heal`**

| Step | Action |
|------|--------|
| 1 | Deploy 3 pods |
| 2 | Partition node-c via NetworkPolicy |
| 3 | Emit domain events from node-a and node-b (via `kubectl exec`) |
| 4 | Emit domain events from node-c (isolated, separate history) |
| 5 | Heal partition |
| 6 | Wait for anti-entropy sync |
| 7 | Assert all 3 pods have identical event hash sets (no duplicates, no missing) |

#### 6.6 Pytest Configuration

```python
@pytest.mark.integration  # All cluster-dependent tests
@pytest.mark.e2e           # Full pod deployment tests
@pytest.mark.slow          # Tests > 30 seconds
@pytest.mark.timeout(300)  # 5-minute timeout for pod tests
```

#### 6.7 Verification Gate

```bash
poetry run pytest -m "not integration"    # Unit tests pass
poetry run pytest -m integration          # All integration tests pass
poetry run pytest -m e2e --timeout=300    # Pod-based tests pass
```

---

### Phase 7: TLA+ Model Extension

**Goal**: Extend the formal model to cover GatewayClaim/GatewayYield events, DNS write gating, and message delay.

**File**: `documents/engineering/tla/gateway_orders_rule.tla`

#### 7.1 Model Extensions

| Extension | Description |
|-----------|-------------|
| `GatewayClaim` / `GatewayYield` as log entries | Model claim/yield as append-only log entries |
| DNS write as guarded action | Requires `ownerView[n] == n` AND `GatewayClaim(n)` in local log |
| Message delay queue | Replace synchronous heartbeat delivery with message queue (non-synchronous) |

#### 7.2 New Invariants

| Invariant | Property |
|-----------|----------|
| `NoSimultaneousDNSWriters` | At most 1 node performs DNS write per state |
| `ClaimPrecedesWrite` | DNS write only occurs after claim event in local log |
| `YieldPrecedesReclaim` | A node that yielded must see peer acknowledgment before reclaiming |

#### 7.3 Verification

```bash
poetry run prodbox-tla-check    # All invariants pass in TLC model checker
```

---

### Phase 9: Integration Test Expansion

**Goal**: Expand the integration test suite to robustly simulate distributed failure modes not covered by Phase 6.

**Status**: In progress

#### 9.1 New Failure Scenarios

| Test | Failure Mode |
|------|-------------|
| `test_simultaneous_multi_node_crash_leaves_singleton` | 2 of 3 nodes crash, singleton takeover |
| `test_cascading_failure_to_last_node` | Sequential crashes before failover completes |
| `test_flapping_node_convergence` | Rapid crash/restart cycles, convergence stability |
| `test_full_cluster_outage_and_recovery` | All nodes crash and restart |
| `test_asymmetric_partition` | Partial mesh (A↔B, B↔C, A✗C) |
| `test_partition_flap_convergence_stability` | Repeated partition/heal cycles |
| `test_long_partition_event_log_merge` | Extended partition with event accumulation, anti-entropy merge |
| `test_ownership_transition_cycle_verified_behaviorally` | Full transition cycle with event hash convergence verification |

#### 9.2 Key Files

| File | Change |
|------|--------|
| `tests/integration/test_gateway_k8s_pods.py` | 8 new test functions |
| `tests/integration/k8s_manifests.py` | Asymmetric partition NetworkPolicy generator |
| `tests/integration/conftest.py` | Fixture contract documentation |

---

### Known Technical Debt

All known technical debt items from this cycle have been resolved:
- **DNS write yield guard bug** — fixed in WI-1 (`has_active_claim_from()` replaces `has_claim_from()`)
- **TLA+ election divergence** — resolved in WI-2 (model aligned with rank-ordered implementation)
- **TLC not yet executed** — resolved in WI-2 (6 invariants verified over 4.4M distinct states)

---

## 9. Implementation Order and Dependencies

Phases 1-8 complete. Phase 9 in progress. Implementation order:

```
Phase 1-2: Foundation (Orders, CommitLog, mTLS gossip, gateway rule)
    │
    ▼
Phase 3: GatewayClaim/GatewayYield events
    │
    ▼
Phase 4: DNS write gating
    │
    ▼
Phase 5: K8s pod infrastructure (manifests, fixtures)
    │
    ▼
Phase 6: K8s pod integration tests (mesh, failover, partition)
    │
    ▼
Phase 7: TLA+ model extension (bounded timestamps, claim/yield invariants)
    │
    ▼
Phase 8: Gateway hardening (REST API, Route53 client, CLI command group)
    │
    ▼
Phase 9: Integration test expansion (distributed failure simulation)
```

### Key Files Per Phase

| Phase | Files |
|-------|-------|
| **3** | `src/prodbox/gateway_daemon.py`, `tests/unit/test_gateway_daemon.py` |
| **4** | `src/prodbox/gateway_daemon.py`, `tests/unit/test_gateway_daemon.py` |
| **5** | `tests/integration/k8s_manifests.py`, `tests/integration/conftest.py`, `tests/integration/helpers.py` |
| **6** | `tests/integration/test_gateway_k8s_pods.py` |
| **7** | `documents/engineering/tla/gateway_orders_rule.tla`, `documents/engineering/tla/gateway_orders_rule.cfg` |
| **8** | `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/effects.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/main.py` |
| **9** | `tests/integration/test_gateway_k8s_pods.py`, `tests/integration/k8s_manifests.py`, `tests/integration/conftest.py`, `documents/engineering/tla_modelling_assumptions.md` |

---

## 10. Configuration

All configuration via environment variables. Pydantic `Settings` validates on load.

### Required Variables

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key for Route 53 |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `ROUTE53_ZONE_ID` | Route 53 hosted zone ID |
| `ACME_EMAIL` | Email for Let's Encrypt registration |

### Optional Variables (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-1` | AWS region |
| `DEMO_FQDN` | `demo.example.com` | Domain name |
| `DEMO_TTL` | `60` | DNS record TTL (seconds) |
| `METALLB_POOL` | `192.168.1.240-192.168.1.250` | MetalLB IP range |
| `INGRESS_LB_IP` | `192.168.1.240` | Traefik LoadBalancer IP |
| `KUBECONFIG` | `~/.kube/config` | Path to kubeconfig |
| `ACME_SERVER` | Let's Encrypt production | ACME server URL |
| `PULUMI_STACK` | `home` | Pulumi stack name |

---

## 11. Operations

### Deploy Workflow

```bash
prodbox env validate         # Validate configuration
prodbox host ensure-tools    # Verify required CLI tools
prodbox pulumi stack-init    # Initialize Pulumi stack (first time)
prodbox pulumi preview       # Preview infrastructure changes
prodbox pulumi up            # Deploy infrastructure
```

### DDNS Setup

```bash
prodbox dns ensure-timer     # Install systemd timer for DDNS updates
prodbox dns check            # Verify current DNS record
prodbox dns update           # Manual DNS update
```

### Health Checking

```bash
prodbox k8s health           # Check cluster and component health
prodbox k8s wait             # Wait for deployments to be ready
```

### Teardown

```bash
prodbox pulumi destroy       # Destroy all managed resources
```

---

## 12. Quality Standards

### Type Safety

Ultra-strict mypy configuration with zero tolerance for `Any` types:
- `disallow_any_expr = true`, `disallow_any_explicit = true`, `disallow_any_generics = true`
- Custom type stubs in `typings/` for external libraries
- Exception: unavoidable `Any` from Python stdlib async APIs and Pydantic/Pulumi (documented with targeted `type: ignore` comments)

### Testing

- 746 tests with 95%+ coverage target (excluding `infra/`)
- [Interpreter-Only Mocking Doctrine](documents/engineering/unit_testing_policy.md): pure code never touches mocks
- pytest-subprocess for subprocess mocking in interpreter tests
- Integration tests use real effects (no mocking), require live RKE2 cluster
- Pytest markers: `@pytest.mark.integration`, `@pytest.mark.e2e`, `@pytest.mark.slow`

### Pure FP Standards

- [Pure FP coding standards](documents/engineering/pure_fp_standards.md) enforced across all non-interpreter code
- Frozen dataclasses, `tuple`/`frozenset` collections, `match/case` over `if/else`
- `Result[T, E]` for error handling, no exceptions for control flow

### Linting

- Ruff for linting and formatting (`ruff check`, `ruff format`)
- 100-character line length, isort import ordering
- Zero errors required on both `ruff check` and `ruff format --check`
