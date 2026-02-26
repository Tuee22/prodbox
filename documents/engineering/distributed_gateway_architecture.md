# Distributed Gateway Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/README.md

> **Purpose**: Define the multi-node gateway design for prodbox, including failover, peer discovery, and formal safety invariants.

---

## 1. Problem Statement

prodbox currently assumes a single node owns the public gateway DNS record.
Target behavior is:

1. There are `N` prodbox nodes.
2. Exactly one node is the active gateway at a time.
3. The active gateway owns `prodbox.resolvefintech.com`.
4. Every node has a stable per-node DNS record, e.g. `node-3.prodbox.resolvefintech.com`.
5. Nodes can be offline for long periods and rejoin without cluster disruption.
6. Leadership safety must be specified and model-checked with TLA+.

---

## 2. Current Repository Findings

### 2.1 DNS command path is still single-node

- `dns update` currently builds a DAG whose root effect is only `FetchPublicIP`.
- The builder has a TODO note indicating DNS workflow expansion is still pending.

Source:
- `src/prodbox/cli/dag_builders.py`

### 2.2 Route 53 effects exist but are not wired into the DNS DAG root

- Interpreter handlers exist for querying/updating Route 53.
- Prerequisites validate AWS credentials, but command DAG roots do not yet compose a full lease/election workflow.

Source:
- `src/prodbox/cli/interpreter.py`
- `src/prodbox/cli/prerequisite_registry.py`

### 2.3 Infrastructure defines one A record only

- Pulumi deploys a single A record (`demo_fqdn`) and ignores record-value drift so DDNS can mutate it.
- No concept of per-node DNS records, lease state, or leadership resource exists yet.

Source:
- `src/prodbox/infra/dns.py`
- `src/prodbox/infra/__main__.py`

### 2.4 Runtime model is timer-driven, not leader loop-driven

- Systemd timer periodically invokes `prodbox dns update`.
- This works for DDNS but not for robust lease renew/failover semantics.

Source:
- `scripts/route53-ddns.service`
- `scripts/route53-ddns.timer`

---

## 3. Key Design Constraint

**Route 53 alone cannot provide provable mutual exclusion for leadership.**

Reason: Route 53 has no conditional compare-and-swap primitive for record updates.
Without linearizable CAS, two nodes can race and overwrite each other, which is exactly the tug-of-war failure mode.

Therefore:

1. Leadership must be decided in a linearizable lease store.
2. Route 53 must be treated as an eventually consistent projection of current leader state.

---

## 4. Proposed Architecture

## 4.1 Data Plane (Route 53)

1. Gateway record:
   - `prodbox.resolvefintech.com` (A) -> active leader public IP
2. Stable node records:
   - `node-{id}.prodbox.resolvefintech.com` (A/AAAA) -> node public IP
3. Optional metadata record:
   - `_gateway.prodbox.resolvefintech.com` (TXT) -> `owner=node-3,epoch=42`

## 4.2 Control Plane (DynamoDB Lease)

Single-item lease row keyed by `resource = "gateway"`:

- `owner_id: str`
- `lease_epoch: int` (monotonic fencing token)
- `lease_expires_at: int` (unix seconds)
- `owner_ip: str`
- `updated_at: int`

Acquire/renew uses conditional writes. This is the safety boundary.

## 4.3 Node Runtime

Replace timer-only leadership with a small daemon loop:

1. Try acquire/renew lease every `renew_interval`.
2. If lease held, project gateway A record (on IP change or periodic reconcile).
3. If lease lost/expired, stop projecting immediately.
4. Keep node-specific DNS fresh independently of leadership.

---

## 5. Lease + Fencing Algorithm

## 5.1 Acquire

Node `n` attempts conditional update:

- Condition: lease missing OR expired OR already owned by `n`
- Update:
  - `owner_id = n`
  - `lease_epoch = previous_epoch + 1` on takeover, unchanged on renew
  - `lease_expires_at = now + lease_duration`

## 5.2 Renew

Only current owner can renew before expiry.
If renew fails condition, node demotes itself immediately.

## 5.3 Project to Route 53

A node may update gateway DNS only while:

1. It is current lease owner, and
2. Its local epoch equals lease row epoch.

Use jittered backoff for retries to reduce write contention.

## 5.4 Safety Model

- Safety comes from lease ownership, not from Route 53 state.
- Route 53 is a projection and may lag temporarily due propagation and TTL.

---

## 6. Eventually Consistent Cluster State

Gateway leadership and cluster state should be separated:

1. Leadership: strict lease semantics (single-writer ownership).
2. Shared node state: eventually consistent anti-entropy.

Recommended shared state pattern:

- Per-key LWW register with version tuple `(logical_counter, node_id)`.
- Periodic peer gossip over stable node DNS names.
- On rejoin, node does full-state pull from one reachable peer, then resumes incremental gossip.

This supports long offline periods and deterministic convergence.

---

## 7. TLA+ Scope

The TLA+ model should prove at minimum:

1. `MutualExclusion`: at most one valid lease holder.
2. `NoTugOfWar`: no two nodes can simultaneously satisfy gateway-serving lease predicate.
3. `EpochMonotonicity`: lease epoch never regresses.
4. `FailoverLiveness`: if a leader goes silent and at least one node is alive, leadership eventually reappears.

Initial spec is provided at:

- `documents/engineering/tla/gateway_lease.tla`
- `documents/engineering/tla/gateway_lease.cfg`

---

## 8. Incremental Migration Plan

## Phase 1: Identity + infra primitives

1. Add node identity settings (`node_id`, `node_fqdn`, `gateway_fqdn`).
2. Add Pulumi resources for stable node records.
3. Add Pulumi module for DynamoDB lease table.

## Phase 2: CLI runtime leadership

1. Add new effect types for lease acquire/renew/read.
2. Add `prodbox gateway run` daemon command.
3. Keep existing `dns update` as manual reconcile command.

## Phase 3: Peer sync

1. Add peer discovery from stable DNS records.
2. Add anti-entropy state exchange loop.
3. Add merge logic with deterministic ordering.

## Phase 4: Formal + chaos validation

1. Expand TLA+ model with crash/recover and delayed DNS projection actions.
2. Add simulation tests for split-brain and churn scenarios.
3. Add failure-injection integration tests.

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Documentation Standards](../documentation_standards.md)
