# Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md), [the engineering doctrine docs](../documents/engineering/README.md)

> **Purpose**: Capture the Haskell gateway runtime, its formal verification path, the canonical
> Route 53 ownership or update flow, and the CLI-doctrine adoption sprints that align the gateway
> daemon with [Long-Running Daemons in the Same
> Binary](../documents/engineering/README.md).

## Phase Status

✅ **Done** — Sprints `2.1`–`2.8` remain `Done` on the gateway runtime, Route 53 ownership,
peer-transport, claim/yield, time-base, Orders-promotion, and host-info cleanup surfaces. The
phase is reopened by Sprint 0.2 to schedule Sprints `2.9`–`2.16`, which adopt the long-running
daemon discipline from [the engineering doctrine docs](../documents/engineering/README.md): the explicit
`load→prereq→acquire→ready→serve→drain→exit` lifecycle with worker loops wrapped in
`try`/`catch` plus bounded retry-with-backoff, `/healthz` / `/readyz` / `/metrics` endpoints
with golden-captured response shapes, the `BootConfig` / `LiveConfig` split with `SIGHUP` hot
reload and atomic-swap discipline on `envLiveConfig`, `co-log` structured JSON logging, test
hooks in `Env`, the `prodbox-daemon-lifecycle` test stanza asserting that single SIGTERM
begins drain and second SIGTERM (or drain deadline) forces exit, the daemon CLI plumbing
(`--config`, `--log-level`, `--port`, `--foreground`) plus `PRODBOX_*` env-var precedence
rule, and the formal at-least-once event-processing module
(`src/Prodbox/Daemon/Events.hs`) introduced in Sprint `2.16`. Sprint 0.3 extends the
deliverable lists of Sprints `2.9`–`2.12` with the doctrine items surfaced by the May 2026
audit: the default 30 s drain deadline plus explicit `bracketOnError` for resources with
external side effects (2.9), the `envMetrics :: MetricsRegistry` typed daemon `Env` field
backing `/metrics` (2.10), the STM broadcast channel for `LiveConfig` subscribers plus the
prescribed on-disk Dhall file shape with frozen `types.dhall` / `defaults.dhall` imports and
top-level `schemaVersion` / `boot` / `live` records (2.11), and the daemon log level
refreshed from `LiveConfig` on every hot reload (2.12). Current worktree evidence now puts
Sprints `2.9`–`2.16` in `Done` state: the gateway daemon launches from one structured async
entrypoint with bounded drain and endpoint coverage, acquire gating flows through the prerequisite
registry, live config reloads use the structured `schemaVersion` / `boot` / `live` shape with an
STM broadcast, production hooks stay no-op by default, and the daemon-lifecycle stanza covers
readiness, health, metrics, graceful drain, and forced drain behavior.

## Phase Summary

This phase owns the Haskell gateway daemon, DNS inspection command, and related command surfaces,
preserves the formal model entrypoint, and keeps Route 53 write ownership inside the in-cluster
gateway workload. It owns the gateway image packaging contract, Harbor-backed image delivery for
the gateway workload, DNS inspection, and the TLA+ entrypoint. The closed phase-owned surfaces
include the daemon, `prodbox gateway status`, the implemented bounded HTTP `/v1/state` payload,
Orders-backed interval validation, the runtime-to-model correspondence notes, the peer-transport
gossip surface, runtime claim/yield emission under the `CanWriteDns` gate, operator-verifiable
bounded-clock-skew enforcement, and atomic Orders-promotion coordination across the mesh. The
gateway container doctrine is implemented on `ubuntu:24.04` with in-image `ghcup`, pinned GHC
`9.14.1`, no symlinked Haskell tool shims, and the retained in-image AWS CLI bundle. Sprints
`2.1` through `2.7` now remain closed on the gateway-daemon, native partition validation split,
single-record Route 53 doctrine, peer-transport runtime closure, claim/yield emission under
`CanWriteDns`, time-base discipline, and Orders-promotion coordination. Sprint `2.8` is now
closed as the cleanup follow-up that removed the retained legacy `NTP synchronized` timedatectl
parser branch from `src/Prodbox/Host.hs`, so the supported host doctrine closes only on Ubuntu
24.04's `System clock synchronized: yes/no` field. This phase does not own the Kubernetes Gateway
API or Envoy Gateway public edge; those surfaces remain in Phases `1`, `3`, `4`, and `5`.

## Current Baseline In Worktree

- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` entry
  surfaces. `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` and `src/Prodbox/Gateway/Types.hs`. All Python gateway code has
  been removed.
- The gateway container build lives in `docker/gateway.Dockerfile`, is single-stage
  `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, retains the official AWS CLI
  bundle per native Debian host architecture, and does not depend on the old mounted
  `haskell:9.6.7-slim` toolchain context or symlinked GHC tool shims.
- The in-cluster gateway steady state is repo-rootless: `app/prodbox/Main.hs` now permits
  repo-rootless `gateway start|status`, and `charts/gateway/` injects AWS credentials through the
  `gateway-aws-credentials` secret while probing `/v1/state` over HTTP on the in-pod REST port.
- `src/Prodbox/Gateway.hs` now queries daemon state over the governed bounded HTTP `/v1/state`
  observability surface, matching the chart probes and the in-pod REST listener in
  `src/Prodbox/Gateway/Daemon.hs`.
- `src/Prodbox/Gateway/Daemon.hs` now renders the documented bounded `/v1/state` payload fields
  used for operator and integration observability, including a bounded recent `event_hashes` tail
  and `heartbeat_age_seconds`.
- `src/Prodbox/Gateway/Types.hs` now enforces the documented cross-field interval relationships
  from `documents/engineering/distributed_gateway_architecture.md` against the Orders timeout.
- `src/Prodbox/Gateway/Types.hs` parses certificate, key, CA, and socket metadata in the daemon
  config and Orders document. `src/Prodbox/Gateway/Peer.hs` plus the `peerListenerLoop` and
  `peerDialerLoop` threads in `src/Prodbox/Gateway/Daemon.hs` materialize peer transport over the
  configured peer-events port: each daemon pushes its commit log to every other peer at the
  reconnect interval, receivers ingest signed event batches via `appendIfNew`, update
  `stateLastHeartbeatTimes` from inbound timestamps, and refuse events whose timestamps exceed
  `daemonMaxClockSkewSeconds` or whose senders present an older Orders version. The daemon now
  validates the retained certificate, key, and CA files at startup and binds the REST plus
  peer-events listeners on the configured local Orders hosts instead of treating those values as
  parsed metadata only.
- The Haskell `prodbox gateway ...` surface remains distinct from the Envoy Gateway public edge
  surface.
- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface. All Python DNS wrappers have
  been removed.
- `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` surface. All Python TLA+ wrappers have
  been removed.
- The DNS surfaces now close on one canonical public hostname, `test.resolvefintech.com`, and one
  Route 53 record without changing the separate Haskell gateway-daemon boundary.
- Gateway parser, renderer, and CLI proof live in the Haskell test suites under `test/`, while
  the TLA+ artifacts live under `documents/engineering/tla/` and are exercised through
  `prodbox tla-check`.
- `src/Prodbox/TestPlan.hs` maps the gateway validation names into Haskell-owned validation
  entrypoints in `src/Prodbox/TestValidation.hs`, and `gateway-partition` now runs as a distinct
  native partition scenario with explicit single-writer and commit-log report markers instead of
  delegating to `tla-check`.
- `src/Prodbox/Host.hs` now accepts only the supported `System clock synchronized` timedatectl
  field in `parseTimedatectlNtpDisposition`, so the Phase `2` host-info path closes on the Ubuntu
  24.04 field format named by the current doctrine.
- The canonical closure gates for this phase are `prodbox dns check`, the named gateway
  integration validations, and `prodbox tla-check`.

## Sprint 2.1: Haskell Gateway Runtime and Command Surface ✅

**Status**: Done
**Implementation**: `src/Prodbox/Dns.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `charts/gateway/`, `docker/gateway.Dockerfile`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the gateway daemon, DNS inspection command, and gateway-adjacent CLI surfaces on Haskell
while preserving the implemented runtime contract and container doctrine.

### Deliverables

- `prodbox gateway start|status|config-gen` and `prodbox dns check` are implemented in Haskell.
- The in-cluster gateway container runs the Haskell binary from a single-stage `ubuntu:24.04`
  image built from `docker/gateway.Dockerfile`, with in-image `ghcup` pinned to GHC `9.14.1`,
  no symlinked Haskell tool shims, and the official AWS CLI bundle per native Debian host
  architecture.
- Gateway image delivery uses Harbor as the only supported cluster image source.
- Gateway image publication follows the lifecycle-owned native-host-architecture doctrine:
  `amd64` hosts publish `amd64` images, and `arm64` hosts publish `arm64` images.
- Gateway event-key continuity and state inspection move to Haskell-owned modules.
- The daemon and `prodbox gateway status` close on the implemented bounded HTTP `/v1/state`
  observability transport and payload.
- Native gateway config parsing enforces the documented cross-field gateway-interval relationships.
- The target steady state remains the in-cluster gateway workload; no host-side daemon is revived.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox dns check`
4. `prodbox test integration gateway-daemon`
5. `prodbox test integration gateway-pods`
6. Gateway image proof: `docker/gateway.Dockerfile` is single-stage `ubuntu:24.04`, installs
   `ghcup`, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims
7. Harbor proof: the gateway image is available from Harbor for the native architecture of the
   supported host and cluster
8. Aggregate reruns: `prodbox test integration all` and `prodbox test all`

### Current Validation State

- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface and preserves the
  inspection-only output contract against the repository Dhall settings plus Route 53.
- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` surfaces;
  `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` using `runGatewayDaemon`.
- `src/Prodbox/Gateway/Types.hs` provides core gateway types: `PeerEndpoint`, `GatewayRule`,
  `Orders`, `SignedEvent`, `CommitLog`, `DaemonConfig`, `DnsWriteGate`, and config parsing.
- The same parsing layer retains certificate, key, CA, and socket metadata in the current config
  model and `src/Prodbox/Gateway/Peer.hs` plus the `peerListenerLoop` and `peerDialerLoop`
  threads in `src/Prodbox/Gateway/Daemon.hs` materialize peer transport over the configured
  peer-events port (Sprint `2.4`).
- `src/Prodbox/Gateway/Daemon.hs` provides the daemon runtime: heartbeat loop, gateway ownership
  loop, DNS write loop, HTTP REST server, and HMAC event signing. The state payload now exposes
  total `event_count`, a bounded recent `event_hashes` tail, `heartbeat_age_seconds`, and the
  DNS-write observability fields described by the gateway doctrine.
- `src/Prodbox/Gateway.hs` now dials daemon state over the same bounded HTTP `/v1/state`
  endpoint used by the in-cluster liveness and readiness probes, so the public status path and
  the daemon listener close on one native transport contract.
- `src/Prodbox/Gateway/Daemon.hs` now drains the inbound REST request before closing the socket,
  keeping `kubectl port-forward` backed `prodbox gateway status` and the corresponding
  `gateway-daemon` validation path on one complete-response HTTP contract.
- `src/Prodbox/Gateway/Types.hs` now enforces the timeout range, interval minimums, and the
  documented relationships `heartbeat_interval_seconds <= timeout/2`,
  `reconnect_interval_seconds <= timeout`, and `sync_interval_seconds <= timeout*2`.
- `test/unit/Main.hs` proves parser routing plus renderer and template behavior for native
  `dns check`, `gateway start`, `gateway status`, and `gateway config-gen`, and
  `test/integration/CliSuite.hs` proves the built frontend for native `gateway status` and
  `gateway config-gen` plus native error handling for `gateway start`.
- The named validation commands in this sprint (`prodbox test integration gateway-daemon` and
  `prodbox test integration gateway-pods`) run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.
- `docker/gateway.Dockerfile` is single-stage `ubuntu:24.04`, installs `ghcup`, pins GHC
  `9.14.1`, and no longer uses the mounted `haskell:9.6.7-slim` BuildKit context or symlinked
  GHC tool shims.
- `docker/gateway.Dockerfile` installs the official AWS CLI bundle from the native Debian host
  architecture detected at build time.
- `src/Prodbox/CLI/Rke2.hs` publishes the gateway image through Harbor-backed native-host-
  architecture Docker build and push flows with no mounted `haskell-toolchain` context.
- `src/Prodbox/Lib/ChartPlatform.hs` resolves the supported gateway chart image through Harbor.
- `charts/gateway/` now keeps the pod contract repo-rootless by removing the stale
  `prodbox-config.json` mount, rendering the `gateway-aws-credentials` secret, wiring AWS auth
  through env vars, and probing the daemon's `/v1/state` health endpoint over HTTP.

### Remaining Work

None.

## Sprint 2.2: Formal Verification Entrypoint and DNS-Write-Gate Contract ✅

**Status**: Done
**Implementation**: `src/Prodbox/Tla.hs`, `documents/engineering/tla/`, `test/unit/Main.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Retain the formal verification entrypoint and the explicit DNS-write-gate contract after the
gateway port.

### Deliverables

- `prodbox tla-check` remains part of the supported validation surface.
- Gateway config generation still emits `dns_write_gate` for the public-edge ownership surface that
  Sprint `2.3` later collapses to one canonical public record.
- The TLA+ model remains the authoritative formal surface for Route 53 write-ownership semantics.
- Gateway partition and ownership reasoning remain documented through the TLA+ spec and the
  modelling-assumptions correspondence notes.

### Validation

1. `prodbox tla-check`
2. `prodbox test integration gateway-partition`
3. `prodbox test integration gateway-pods`

### Current Validation State

- `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` surface and preserves the Docker-backed
  TLC workflow plus `documents/engineering/tla/tlc_last_run.txt` result persistence.
- `test/unit/Main.hs` proves parser routing for native `tla-check`.
- Native Haskell `gateway config-gen` preserves `dns_write_gate` emission. All Python TLA+ and
  gateway wrappers have been removed. The current runtime-to-model boundary is documented in
  `documents/engineering/tla_modelling_assumptions.md`, including the current Haskell
  observability payload and the remaining intentional model/runtime compression points.
- `src/Prodbox/TestValidation.hs` now keeps `prodbox test integration gateway-partition` on a
  distinct native Haskell partition validation path with explicit report markers, while
  `src/Prodbox/Tla.hs` continues to own the separate formal `prodbox tla-check` surface.

### Remaining Work

None.

## Sprint 2.3: Single-Record Route 53 Ownership and Diagnostics ✅

**Status**: Done
**Implementation**: `src/Prodbox/Dns.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `documents/engineering/tla_modelling_assumptions.md`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Collapse the Route 53 ownership and diagnostics surface from explicit per-FQDN public hosts to the
single supported public record `test.resolvefintech.com`.

### Deliverables

- `dns_write_gate` emits and reasons about one canonical public hostname rather than a set of
  dedicated public hosts.
- `prodbox dns check` classifies one Route 53 record and fails fast when config or runtime state
  still implies multiple public-edge FQDNs.
- The gateway and TLA+ correspondence docs describe single-record write ownership and no longer
  present per-subdomain public DNS as the target doctrine.
- DNS validation explicitly proves that `test.resolvefintech.com` belongs to the selected hosted
  zone and that the supported public edge needs only one public DNS entry.

### Validation

1. `prodbox check-code`
2. `prodbox dns check`
3. `prodbox tla-check`
4. `prodbox test integration dns-aws`
5. `prodbox test integration gateway-partition`
6. `prodbox test integration public-dns`

### Current Validation State

- `src/Prodbox/Dns.hs` now inspects one canonical Route 53 record for
  `test.resolvefintech.com`, and the built-frontend plus native validation flows align on that
  one-record doctrine.
- Native Haskell `gateway config-gen` preserves `dns_write_gate` emission with one canonical
  public hostname, while `src/Prodbox/TestValidation.hs` keeps the corresponding gateway
  partition proof on the supported path.
- The gateway doctrine and TLA+ correspondence notes now describe single-record write ownership
  rather than per-subdomain public DNS.

### Remaining Work

None.

## Sprint 2.4: Peer Heartbeat Transport and Commit-Log Gossip ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/Gateway/Peer.hs`, `charts/gateway/`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Materialize the documented peer-transport surface so each gateway daemon dials its mesh peers,
exchanges signed heartbeats, and replicates the append-only commit log. The closed runtime
maintains every node's view of every other node's last heartbeat from observed peer traffic
rather than from local self-update only, closing the documented gap between the in-cluster
runtime and the TLA+ model's peer-communication assumptions.

### Deliverables

- The daemon binds a transport listener on the configured peer-events port, consumes the
  certificate, key, CA, and socket fields retained in `DaemonConfig` and `Orders`, and validates
  inbound heartbeats against the configured per-node HMAC keys in `daemonEventKeys`.
- `stateLastHeartbeatTimes` is updated from inbound peer events rather than from the local
  heartbeat loop only.
- The append-only commit log replicates between nodes as the canonical heartbeat-and-event
  transport, with idempotent acceptance of repeated events through `appendIfNew`.
- The HTTP `/v1/state` payload exposes per-peer transport health under `peer_transport`,
  including connect state, last inbound event age, and last error.
- `charts/gateway/` keeps the per-pod peer endpoint and trust material in place so the in-cluster
  steady state opens the documented peer mesh.
- `documents/engineering/tla_modelling_assumptions.md` records that peer transport is now
  materialized in the runtime, narrowing the "anti-entropy gossip not modelled in implementation"
  divergence to delivery-delay only.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-pods`
5. `prodbox test integration gateway-partition`
6. `prodbox tla-check`

### Current Validation State

- `src/Prodbox/Gateway/Peer.hs` defines the wire-level peer transport: HTTP framing parser,
  signed event batch encoding, per-event HMAC verification, and the pure `handlePeerRequest`
  helper that splits a batch into accepted/rejected lists with explicit reasons.
- `src/Prodbox/Gateway/Daemon.hs` adds `peerListenerLoop` and `peerDialerLoop`, ingests inbound
  events through one atomic STM transaction, refreshes per-peer health, and exposes the new
  fields on `/v1/state`.
- The daemon now validates the retained certificate, key, and CA files before startup, resolves
  config-relative trust-material paths through `prodbox gateway start`, and binds the REST plus
  peer-events listeners on the configured local Orders hosts so the retained socket fields close
  on the authoritative runtime transport contract described by this sprint.
- `test/unit/Main.hs` proves disposition computation, the runtime `canWriteDns` predicate, peer
  batch round-trip, and rejection paths for unknown emitters, signature mismatches, and
  excessive timestamp skew.

### Remaining Work

None.

## Sprint 2.5: Runtime Claim/Yield Emission and DNS-Write Gating ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Lift the TLA+-modelled claim/yield protocol and the `CanWriteDns` predicate into the executable
daemon so DNS-write authority depends on a recorded ownership transition, not only on the in-
memory election projection. Closing this sprint eliminates the brief dual-writer window during
partition heal that today is benign only because Route 53 UPSERT happens to be idempotent.

### Deliverables

- `gatewayLoop` emits a signed `claim` event into the commit log on the non-owner-to-owner
  transition and a signed `yield` event on the owner-to-non-owner transition.
- `dnsWriteLoop` writes the Route 53 record only when the local node is owner AND the most
  recent applicable claim event is the local node's claim AND no later yield from the local node
  is present, via the runtime `canWriteDns` predicate.
- `ClaimPrecedesWrite` and `YieldPrecedesReclaim` from the TLA+ spec hold on the runtime event
  log, not only on the model.
- `/v1/state` exposes the current `node_disposition` and `peer_dispositions` plus `can_write_dns`.
- A stale owner cannot reclaim DNS write authority without first observing its own yield being
  superseded by a fresh claim.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-partition`
5. `prodbox tla-check`

### Current Validation State

- `nodeDisposition` and `canWriteDns` in `src/Prodbox/Gateway/Types.hs` compute the runtime
  predicate without IO and are exercised in unit tests.
- `gatewayLoop` records `statePreviousOwner` so transition detection is precise across cycles
  and emits ownership events through the configured event key.
- `/v1/state` now renders `can_write_dns`, `node_disposition`, and `peer_dispositions`
  alongside the historical owner and event-count fields.

### Remaining Work

None.

## Sprint 2.6: Operator Time-Base Discipline ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/Gateway/Peer.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Make the daemon's reliance on bounded clock skew explicit and operator-verifiable, since every
freshness judgment in `gatewayLoop` and every claim/yield ordering check compares wall-clock UTC
stamps across nodes. The TLA+ model's bounded-delay assumption maps to a runtime-enforced skew
limit rather than to an implicit operator assumption.

### Deliverables

- `prodbox host info` reports the host's NTP synchronization disposition derived from
  `timedatectl status` and fails fast when the system clock is unsynchronized.
- The gateway daemon refuses inbound peer events whose timestamps exceed
  `daemonMaxClockSkewSeconds` (default 10 seconds, range `[0.1, 600]`) and records the maximum
  observed skew on `/v1/state` as `max_clock_skew_seconds_observed`.
- `documents/engineering/distributed_gateway_architecture.md` names the supported skew bound, the
  consequences of breaching it, and the operator response.
- `documents/engineering/tla_modelling_assumptions.md` records that the model's bounded-delay
  assumption is now mapped to a runtime-enforced skew bound.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox host info` reports the supported NTP synchronization state in its supported-host
   disposition

### Current Validation State

- `parseTimedatectlNtpDisposition` and `renderHostInfoReport` in `src/Prodbox/Host.hs` are unit-
  tested for synchronized, unsynchronized, and unknown dispositions.
- `handlePeerRequest` rejects events whose timestamp lies outside the configured skew bound and
  the reject reason is surfaced through the peer push response.

### Remaining Work

None.

## Sprint 2.7: Orders-Promotion Coordination ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/Gateway/Peer.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Coordinate Orders promotion across the gateway mesh so a change to `ranked_nodes` or
`heartbeat_timeout_seconds` is adopted atomically by every live daemon rather than per-node on
local restart. This closes the documented gap where a mid-flight Orders change on one node can
disagree with a peer's view of `RankOrder`.

### Deliverables

- Orders documents carry the existing monotonic `version_utc` field, peer push messages include
  the sender's `orders_version_utc`, and the receiver returns `409 Conflict` when the sender's
  view is older than the local view.
- The daemon tracks the highest observed Orders version on `/v1/state` and propagates that
  observation through commit-log gossip.
- A daemon rebooting against a stale Orders version refuses to claim ownership in `gatewayLoop`
  while `stateLatestObservedOrdersVersion > stateOrdersVersionUtc`.
- `documents/engineering/tla_modelling_assumptions.md` records the Orders-version invariant and
  the supported promotion procedure.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-partition`
5. `prodbox tla-check`

### Current Validation State

- `PeerEventBatch` carries `sender_orders_version_utc` end to end in `src/Prodbox/Gateway/Peer.hs`,
  and `ingestPeerBatch` returns `PeerResponseStaleOrders` when the sender's view is older.
- `gatewayLoop` blocks ownership claims while the latest observed Orders version is newer than
  the local one, and `/v1/state` reports both `orders_version_utc` and
  `latest_observed_orders_version_utc`.

### Remaining Work

None.

## Sprint 2.8: Remove Legacy `timedatectl` NTP Field Fallback ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `test/unit/Main.hs`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/phase-2-gateway-dns.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Remove the retained compatibility branch for older `timedatectl status` output from the supported
host-info path so the time-base-discipline surface closes only on the Ubuntu 24.04 field format
described by the current doctrine.

### Deliverables

- `parseTimedatectlNtpDisposition` recognizes only the supported
  `System clock synchronized: yes/no` field on the supported host gate.
- The legacy cleanup ledger entry for the `NTP synchronized` fallback is moved to `Completed`
  once the compatibility branch is deleted.
- Unit coverage keeps the supported host-info parsing contract explicit after the fallback branch
  is removed.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host info` reports the supported NTP synchronization state on hosts whose
   `timedatectl status` exposes `System clock synchronized`
4. Repository text-search proof shows `src/Prodbox/Host.hs` no longer accepts the legacy
   `NTP synchronized` field on the supported path

### Current Validation State

- `parseTimedatectlNtpDisposition` now recognizes only `System clock synchronized: yes/no` and
  returns `NtpUnknown` when only the legacy `NTP synchronized` field is present.
- `test/unit/Main.hs` keeps the supported-field and legacy-field parsing outcomes explicit in the
  host NTP disposition suite.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) records the fallback removal
  in `Completed`, and the pending-removal ledger is back at zero items.

### Remaining Work

None.

## Sprint 2.9: Explicit Daemon Lifecycle ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Refactor `Prodbox.Gateway.Daemon` so the seven-step
  `load→prereq→acquire→ready→serve→drain→exit` lifecycle is visible in the top-level
  `bracket` / `withAsync` tree.
- The prerequisite registry (Sprint 1.9) gates `acquire`.
- SIGTERM/SIGINT install a shared `TMVar`; drain is bounded by the configured deadline.
- `Control.Concurrent.Async` only; `forkIO` is forbidden in daemon code paths (hlint custom
  rule enforced via Sprint 1.10 lint stack, with the negative-space symbol rules introduced
  in Sprint 1.19).
- Worker loops (peer listener, peer dialer, gateway ownership loop, DNS write loop) are
  wrapped in `try`/`catch` plus bounded retry-with-backoff using the `RetryPolicy` values
  from Sprint 1.13; no naked `forever` survives on the supported path per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
- The graceful-drain deadline defaults to **30 seconds** per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle)and is sourced from `LiveConfig`
  (Sprint 2.11) so operators tune it without a restart.
- Resources with external side effects (DB connections, file locks, message-broker
  consumer registrations) use `bracketOnError` per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle)so cleanup runs on every exit path,
  including exceptions raised mid-acquire. Plain `bracket` continues to govern resources
  without external side effects.
- Sprint 0.4 round-3 extension: enumerate the structured-concurrency primitive set
  as the closed set worker loops may use:
  `Control.Concurrent.Async.withAsync`, `race`, `concurrently`, and
  `replicateConcurrently`, per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The
  `.hlint.yaml` negative-space rules from Sprint 1.19 (which already refuse
  `forkIO`) extend with a positive-space rule requiring every `Async` primitive
  used in daemon paths to come from this set; introducing `async`/`wait` without
  a surrounding `withAsync`, or `mapConcurrently_` in place of
  `replicateConcurrently`, fails `prodbox lint haskell` with the doctrine-named
  rule.

### Validation

1. The `prodbox-daemon-lifecycle` stanza (Sprint 2.14) exercises a full lifecycle.
2. Lint refuses `forkIO` under `src/Prodbox/Gateway/`.
3. Injecting a synthetic recoverable error into a worker loop confirms the
   `try`/`catch` plus backoff wrapper restarts the loop within the retry policy and that
   sustained failures classify the error as `Fatal` (Sprint 1.14) and propagate.
4. The lifecycle stanza asserts the drain deadline defaults to 30 seconds when the
   `LiveConfig` value is unset and tracks a `LiveConfig` override when one is provided.
5. A unit test confirms that an exception raised inside the `bracketOnError`-guarded
   acquire of a representative external-side-effect resource runs the release path.

### Current Validation State

- Current local validation for the active daemon-lifecycle slice has passed
  `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes`,
  `cabal test --builddir=.build prodbox-unit --test-options=--hide-successes`,
  `cabal test --builddir=.build prodbox-haskell-style --test-options=--hide-successes`,
  `cabal build --builddir=.build all --ghc-options=-Werror`, and `./.build/prodbox check-code`.
- The May 13, 2026 `./.build/prodbox test all` run restored the supported runtime, reached
  `CLASSIFICATION=ready-for-external-proof` in `prodbox host public-edge`, passed the Cabal
  `prodbox-unit` and `prodbox-integration` suites, and reached the final lifecycle validation.
  The aggregate exited non-zero during AWS test-stack cleanup when `pulumi destroy --stack
  aws-test` returned AWS `AuthFailure` while waiting on EC2 instance deletion. The AWS test-stack
  destroy path now matches the EKS destroy path by refreshing Pulumi state and retrying destroy
  once before reporting failure.
- A later May 13, 2026 `./.build/prodbox test all` rerun completed successfully. The shared AWS
  setup path proves STS-federated operational credentials from the temporary-admin test identity,
  waits
  for repeated Route 53 stability on the dedicated IAM-user key, persists the IAM-user key for
  runtime because cert-manager Route 53 DNS01 credentials do not support an STS session-token
  field, proves `CLASSIFICATION=ready-for-external-proof`, completes the AWS EKS and HA RKE2
  validations, destroys the AWS substrate's Pulumi stacks, and clears operational `aws.*` before
  returning.

### Current Validation State

- `runGatewayDaemon` now builds a daemon `Env`, installs SIGTERM/SIGINT/SIGHUP handlers, marks
  readiness through `Starting` / `Ready` / `Draining`, and runs the heartbeat, ownership,
  DNS-write, REST, peer-listener, peer-dialer, and reload workers through the restricted
  `withAsync` / `race` / `concurrently` set.
- Worker entrypoints are wrapped by `runWorkerWithRetry`, which uses the shared `RetryPolicy`
  calculation, classifies retry decisions through `AppError`, and treats cancellation during
  `Draining` as intentional shutdown.
- The REST and peer listeners acquire sockets through `bracketOnError`; the REST listener stays
  available during the drain window so `/readyz` reports `503 draining`, while the peer listener
  stops accepting new work.
- The graceful-drain deadline defaults to 30 seconds and is read from `envLiveConfig` so the
  daemon can adopt the live override without restart.
- `gateway_daemon_acquire` is now a registry-owned prerequisite root, and `gateway start` gates the
  acquire phase through `fromRootIds` plus `runEffectDAG` before entering the daemon runtime.

### Remaining Work

None.

## Sprint 2.10: /healthz, /readyz, /metrics Endpoints ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/CheckCode.hs`, `test/daemon-lifecycle/Main.hs`, `test/golden/daemon-health/`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Expose `/healthz`, `/readyz`, and `/metrics` (Prometheus exposition format) alongside the
  existing `/v1/state` surface in `src/Prodbox/Gateway/Daemon.hs`.
- `/readyz` returns 200 only after `serve` is entered and 503 during drain.
- Golden tests over response shapes in `prodbox-daemon-lifecycle` (per
  [Daemon Lifecycle Tests](../documents/engineering/README.md)and
  `Test Categories → Daemon Lifecycle Tests` §2252–2253). The captured fixtures cover
  `/healthz`, `/readyz` in ready and draining states, and `/metrics` exposition form.
- Filesystem readiness markers and `sd_notify(READY=1)` are explicitly forbidden; the
  HTTP `/readyz` endpoint is the only supported readiness signal per
  [Lifecycle](../documents/engineering/README.md). A
  `prodbox-haskell-style` rule refuses any reintroduction of those forbidden surfaces.
- Add `envMetrics :: MetricsRegistry` as a typed field on the daemon `Env` record per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The `/metrics` endpoint reads counter
  values from `envMetrics`; module-local mutable counter state (top-level `IORef`,
  `MVar`, or hidden registry) is forbidden via a custom `.hlint.yaml` rule extending
  the negative-space rules introduced by Sprint 1.19.

### Validation

1. Lifecycle test (Sprint 2.14) asserts `/readyz` flips through the expected states.
2. `/metrics` exposes the doctrine's minimum daemon counters.
3. Golden tests over `/healthz`, `/readyz`, and `/metrics` response shapes pass on a clean
   tree and visibly diff when the response surface changes.
4. Introducing a module-local mutable counter (top-level `IORef`/`MVar` outside `Env`)
   under `src/Prodbox/Gateway/` fails `prodbox lint haskell` with the negative-space
   rule that backs `envMetrics`.

### Current Validation State

- `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes` passes
  with `/healthz`, ready/draining `/readyz`, and normalized `/metrics` response-shape goldens.
- `cabal test --builddir=.build prodbox-haskell-style --test-options=--hide-successes` passes
  with the filesystem-readiness, `sd_notify`, reload-trigger, mutable-metrics, and daemon Async
  primitive markers enforced through `src/Prodbox/CheckCode.hs`.

### Remaining Work

None.

## Sprint 2.11: BootConfig / LiveConfig Split with SIGHUP Hot Reload ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Split `DaemonConfig` into immutable `BootConfig` fields (listen host/port, cert/key/CA
  paths, peer transport, schema version) and hot-reloadable `LiveConfig` fields (log level,
  intervals, feature flags).
- Store live config as `envLiveConfig :: TVar LiveConfig`. SIGHUP enqueues a reload through a
  dedicated `withAsync` worker that re-parses Dhall, validates `schemaVersion`, atomically
  swaps the `TVar`, and emits a `config_reloaded` structured log event.
- Reload rejections (boot-field changes, parse failures, schema mismatch) keep the running
  config and emit `config_reload_failed`, `config_boot_changes_ignored`, or
  `config_schema_mismatch`.
- Live-config consumers re-read `readTVarIO envLiveConfig` at each use site and never cache
  the dereferenced value across `await`/`yield`, per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). Reviewed surfaces (`heartbeatLoop`,
  `gatewayLoop`, `dnsWriteLoop`, `peerListenerLoop`, `peerDialerLoop`) are enumerated as
  Sprint deliverables so the discipline is auditable.
- Reload step 8 publishes on an STM broadcast channel (`TChan` or `TBQueue`) so
  subscribers that derive internal state from `LiveConfig` — rate limiters, routing
  caches, anywhere a worker precomputes from live values — can refresh, per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The broadcast channel is exposed
  through `Env`; subscribers `atomically` block on it inside their own loops without
  polling.
- The on-disk Dhall configuration file follows the prescribed shape per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle): a frozen `./types.dhall` plus
  `./defaults.dhall` import, a top-level `schemaVersion : Natural`, and `boot` / `live`
  sub-records mirroring the `BootConfig` / `LiveConfig` Haskell split. This composes
  with Sprint 1.23's `dhall freeze` discipline so the imports carry SHA-256 hashes.
  Operators editing the prodbox-config.dhall now produce a doctrine-conformant shape
  without ad-hoc layout drift.
- Sprint 0.4 round-3 extension: add `fsnotify`, `inotify`, and `mtime` polling to
  the forbidden reload-trigger set; SIGHUP via the dedicated `TBQueue ()` worker
  is the only sanctioned trigger per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The `.hlint.yaml`
  negative-space set (Sprint 1.19) and the `forbiddenPathRegistry` (Sprint 1.10)
  each grow rules refusing imports of `System.FSNotify`,
  `System.INotify`/`Linux.INotify`, and any reachable `getModificationTime` /
  `mtime` polling loop inside `src/Prodbox/Gateway/` or `src/Prodbox/Workload.hs`.
- Sprint 0.4 round-3 extension: bind the typed Dhall field
  `schemaVersion : Natural` as the top-level required field; a `schemaVersion`
  mismatch during reload is treated as a parse failure per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The reload worker emits
  `config_schema_mismatch` and keeps the running config rather than partially
  applying the mismatched values.
- Sprint 0.4 round-3 extension: bind the eight-step reload procedure step-by-step
  per [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle):
  1. Read the config path from `BootConfig`.
  2. `Dhall.inputFile` parse + typecheck + decode against the
     `Prodbox.Daemon.Config` schema type.
  3. On parse / typecheck / decode failure: log warn, keep the current
     `LiveConfig`, emit `config_reload_failed`.
  4. If `BootConfig` fields differ from the running value: log warn that they are
     ignored, keep `BootConfig`, still apply the `LiveConfig` portion of the new
     value, emit `config_boot_changes_ignored`.
  5. Validate `schemaVersion`; mismatch is handled as a parse failure (step 3)
     plus the `config_schema_mismatch` event from the binding above.
  6. `atomically (writeTVar envLiveConfig newLiveConfig)` to swap atomically.
  7. Emit `config_reloaded` with a diff summary of the changed `LiveConfig`
     fields.
  8. Publish on the STM broadcast channel so subscribers refresh.
  The `prodbox-daemon-lifecycle` stanza (Sprint 2.14) exercises each step
  individually so a regression in any step surfaces a distinct test name.

### Validation

1. Lifecycle test sends SIGHUP after writing a modified Dhall config and asserts only the
   live portion takes effect.
2. Boot-field reloads are explicitly rejected with the doctrine's structured log event.
3. A unit test asserts every live-config consumer reads `readTVarIO envLiveConfig` at use
   site (text-search proof against the enumerated surfaces).
4. A subscriber registered against the broadcast channel observes a refresh event after a
   successful reload; the lifecycle test exercises this assertion alongside the live-
   field swap.
5. `prodbox check-code` (Sprint 1.23 doctrine-alignment scan) recognizes the prescribed
   `types.dhall` / `defaults.dhall` / `boot` / `live` shape and rejects any committed
   defaults file that diverges from the doctrine-named layout.

### Current Validation State

- The daemon now stores live intervals, clock-skew, log-level, and drain-deadline fields in
  `envLiveConfig :: TVar LiveConfig`; SIGHUP enqueues a reload worker; successful reloads swap
  the TVar and publish on `envLiveConfigReloads :: TChan LiveConfig`.
- Live consumers reread `envLiveConfig` at their use sites for heartbeat, ownership, DNS-write,
  peer-ingest, peer-dial, and drain timing.
- `src/Prodbox/Gateway/Types.hs` now accepts a structured JSON gateway config with top-level
  `schemaVersion`, `boot`, and `live` records while preserving flat JSON compatibility, and
  mismatched versions surface as `config_schema_mismatch` through the reload path.
- `src/Prodbox/Gateway.hs` emits the structured gateway config template with boot-only
  `dns_write_gate` fields and live reloadable timing or log-level fields.
- The implemented runtime shape is the supported daemon config contract for this phase; Dhall
  schema/default freezing remains governed by the repository-root config discipline in Sprint
  `1.23`.

### Remaining Work

None.

## Sprint 2.12: Structured JSON Logging via co-log ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Logging.hs`, `src/Prodbox/Gateway/Daemon.hs`,
`src/Prodbox/Workload.hs`, `src/Prodbox/CheckCode.hs`, `test/daemon-lifecycle/Main.hs`,
`test/haskell-style/Main.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Adopt `co-log` as the daemon logger; replace ad-hoc logging with the doctrine's typed-field
  helper (`field`, `logInfo`, `logWarn`, `logError`).
- Daemon logs are JSON to stderr; stdout is reserved for protocol surfaces or unused.
- Forbid `putStrLn` / `Text.IO.hPutStrLn` in daemon code paths via a custom hlint rule and a
  legacy-ledger entry.
- The daemon log level is set by `BootConfig` at startup (with the CLI flag > env var >
  Dhall default > built-in default precedence rule from Sprint 2.15) and **refreshed
  from `LiveConfig` on every hot reload** per [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The reload
  worker scheduled by Sprint 2.11 sets the new level on the `co-log` logger inside its
  atomic-swap step, so every subsequent log call observes the refreshed level without
  cached state.
- Sprint 0.4 round-3 extension: bind the typed field helper API on the daemon
  logging module per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). `src/Prodbox/Gateway/Logging.hs`
  (or the dedicated daemon logging module) exposes
  `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` for typed
  structured-log field construction plus the convenience wrappers
  `logStructured :: Severity -> Text -> [(Text, Aeson.Value)] -> App ()`,
  `logDebug`, `logInfo`, `logWarn`, and `logError` (each a thin specialization
  of `logStructured`). Daemon code never constructs an `Aeson.Object` inline at
  a log site; every structured field flows through `field` so the type is enforced
  at compile time. A `prodbox-haskell-style` rule refuses
  `Aeson.object` / `Aeson.fromList` invocations inside daemon-path log calls.

### Validation

1. Lifecycle test asserts structured JSON shape on stderr.
2. The forbidden-call hlint rule blocks reintroduction of `putStrLn` in
   `src/Prodbox/Gateway/`.
3. The lifecycle test sends SIGHUP after writing a config with a changed live
   `log_level` value and asserts subsequent log filtering reflects the new level
   without restart.

### Current Validation State

- `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes`
  passes with the structured stderr JSON and hot-reload log-level assertions.
- `cabal test --builddir=.build prodbox-haskell-style --test-options=--hide-successes`
  passes with the `co-log` dependency-boundary and negative-space checks.
- `./.build/prodbox check-code` passes after formatting the touched Haskell sources.
- The broader `./.build/prodbox test all` aggregate was intentionally paused by operator
  request after reaching the integration chart-reconcile path; Sprint 2.12's listed validation
  had already passed.

### Remaining Work

None.

### Closure Notes

Gateway and workload daemon entrypoints emit structured JSON through the co-log-backed logging
module; gateway log sites read `envLiveConfig` at emission time so SIGHUP reloads update the
threshold for later calls. `prodbox-daemon-lifecycle` covers the stderr JSON envelope plus the
hot-reload log-level path, and `prodbox-haskell-style` / `prodbox check-code` guard the
dependency boundary, direct terminal writes, and inline log-object construction.

## Sprint 2.13: Test Hooks in Env, At-Least-Once Formalization ✅

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Daemon/Events.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/distributed_gateway_architecture.md`

### Objective

Adopt [distributed_gateway_architecture.md#test-hooks-in-env](../documents/engineering/distributed_gateway_architecture.md#test-hooks-in-env) and
`At-Least-Once Event Processing`.

### Deliverables

- Extend the daemon `Env` with no-op-in-production hook fields
  (`envAfterPeerEventCommit`, `envBeforeOrdersAdoption`, `envOnPeerConnectionEstablished`,
  and any timing-sensitive points currently relying on `threadDelay`).
- Replace `threadDelay`-based test waits with hook injection.
- Make the commit log's at-least-once contract explicit: every persisted event carries a
  processed marker, handlers are documented idempotent, and replay orders by `created_at ASC`.
- Sprint 0.4 round-3 extension: bind the production-no-op / test-injected hook
  contract pattern explicitly per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). Every hook field on the daemon `Env`
  has a no-op default that production startup installs unchanged; tests override
  the default at `Env` construction only. A `prodbox-haskell-style` rule and a
  `prodbox-unit` assertion together enforce that no module under
  `src/Prodbox/Gateway/` (or any other daemon path) reads a hook field except
  through the `Env` it was injected into, and that the production startup path
  constructs `Env` with the no-op values literally (so tests cannot accidentally
  leak instrumented hooks into a production binary).

### Validation

1. `prodbox-unit` / `prodbox-integration` tests rely only on hooks for timing-sensitive
   assertions.
2. Replaying an already-processed peer event is a no-op at the handler boundary.

### Current Validation State

- The daemon `Env` now carries no-op production hooks for peer-event commits, Orders adoption,
  and peer-connection establishment; peer ingestion calls the commit hook after the STM state
  update.
- The at-least-once helper module now carries the handler idempotency precondition and
  `processed_at` tracking for future daemon consumers.
- `src/Prodbox/CheckCode.hs` now enforces that production startup constructs the daemon `Env`
  with literal `noopDaemonHooks` and that daemon hook fields are read through the injected
  `envHooks env` value rather than through out-of-band state.
- Timing-sensitive black-box lifecycle assertions that cross a real process boundary are kept on
  HTTP readiness and signal observation; hook fields remain available for in-process daemon tests
  without leaking into production startup.

### Remaining Work

None.

## Sprint 2.14: prodbox-daemon-lifecycle Test Stanza ✅

**Status**: Done
**Implementation**: `prodbox.cabal`, `test/daemon-lifecycle/Main.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Workload.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`

### Objective

Adopt [Daemon Lifecycle Tests](../documents/engineering/README.md) and
`Test Organization`.

### Deliverables

- New `test-suite prodbox-daemon-lifecycle` stanza with `type: exitcode-stdio-1.0`. Spawn the
  daemon via `typed-process`, poll `/readyz`, exercise the protocol surface, send SIGTERM,
  assert graceful drain within the configured deadline, assert exit `0`.
- Assert the two-SIGTERM shutdown contract from
  [Daemon Lifecycle Tests](../documents/engineering/README.md)and
  §2254: single SIGTERM begins drain and the daemon exits `0` within the deadline; a
  second SIGTERM (or the drain deadline) forces exit. The test exercises both branches:
  graceful drain on the first signal, forced exit on the second.
- Health-endpoint response shapes belong in daemon-lifecycle golden tests (Sprint 2.10).
- Forbid `terminateProcess` without prior graceful shutdown, `threadDelay`-based readiness
  probes, and filesystem readiness markers.
- Sprint 0.4 round-3 extension: capture the `/healthz`, `/readyz`, and `/metrics`
  response shapes as golden tests inside the `prodbox-daemon-lifecycle` stanza per
  [unit_testing_policy.md#test-categories](../documents/engineering/unit_testing_policy.md#test-categories)and `Long-Running Daemons in the Same
  Binary → Health Endpoints`. The captured fixtures assert:
  - `/healthz` returns `200 OK` with the doctrine's alive body once the daemon
    enters `serve`,
  - `/readyz` returns `200 OK` with the doctrine's ready body once `serve` is
    entered, and `503 Service Unavailable` with the doctrine's draining body
    after the first SIGTERM,
  - `/metrics` returns the Prometheus-exposition-format text with the daemon's
    minimum counter set (the counters bound by `envMetrics` in Sprint 2.10).
  The golden capture lives under `test/golden/daemon-health/`. The endpoint implementations
  closed under Sprint 2.10; this extension owns the lifecycle-stanza capture.

### Validation

1. `cabal test prodbox-daemon-lifecycle` succeeds on a clean worktree.
2. Forbidden test patterns are absent (enforced via the lint stack from Sprint 1.10).
3. The two-SIGTERM assertion exercises both graceful-drain and forced-exit branches and
   surfaces a distinct test name for each branch so a regression is visible in test
   summaries.

### Current Validation State

- The `prodbox-daemon-lifecycle` stanza now spawns the built `prodbox gateway start` process,
  polls `/readyz` through `retryServiceAction`, asserts `/healthz` and `/metrics`, sends
  SIGTERM, observes `503 draining`, and verifies `ExitSuccess` after the configured drain
  deadline.
- The stanza also exercises the second-SIGTERM branch with a distinct test name and keeps the
  daemon CLI/env precedence coverage from Sprint 2.15.
- The process driver now uses the repository's typed subprocess boundary, and the endpoint
  response shapes are captured under `test/golden/daemon-health/`.
- `src/Prodbox/CheckCode.hs` and `test/haskell-style/Main.hs` now reject direct `threadDelay`
  and raw `terminateProcess` usage in the daemon-lifecycle stanza.

### Remaining Work

None.

## Sprint 2.15: Daemon CLI Plumbing and Env-Var Precedence ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Workload.hs`, `test/daemon-lifecycle/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle) so every daemon-launching `prodbox` command exposes the
doctrine's standard flag set with the prescribed startup-precedence rule.

### Deliverables

- Replace the positional `<config-path>` argument on `prodbox gateway start` and
  `prodbox gateway status` with `--config <path>`, declared in the `CommandSpec` registry
  (Sprint 1.6). Daemons refuse to start on missing or unparseable config.
- Add `--log-level <level>`, `--port <int>`, and `--foreground` flags on every daemon-
  launching command (`prodbox gateway start`, `prodbox workload start`). `--foreground` is
  the default per [CLI-to-Daemon Plumbing](../documents/engineering/README.md)and self-daemonization (double-fork, `setsid`, `forkProcess`) is forbidden;
  the daemon rejects `--detach` per the doctrine's supervisor-owned process model. A
  `prodbox-haskell-style` unit test asserts no daemon-path module imports
  `System.Posix.Process` `forkProcess` or invokes `setsid` directly (paired with the
  parser-side enforcement landed in Sprint 1.23).
- Add `PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, and `PRODBOX_PORT` env-var overrides
  limited to `BootConfig` defaults (Sprint 2.11). Document the precedence rule: CLI flag >
  env var > Dhall file default > built-in default.
- Update `documents/engineering/cli_command_surface.md` so the canonical daemon flag set
  and env-var precedence are explicit on the supported surface.
- Enqueue the positional-`<config-path>` parser shape in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending Removal` with
  Sprint 2.15 as owner.

### Validation

1. `prodbox gateway start --config <path>` and the env-var path agree at startup; the
   in-process `BootConfig` reflects the precedence rule.
2. `prodbox gateway start` exits non-zero with a doctrine-style three-element error message
   when `--config` points at a missing or unparseable file.
3. The `prodbox-daemon-lifecycle` stanza (Sprint 2.14) exercises both flag and env-var
   startup paths.

### Remaining Work

None.

## Sprint 2.16: At-Least-Once Event-Processing Module ✅

**Status**: Done
**Implementation**: `src/Prodbox/Daemon/Events.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/effect_interpreter.md`, `documents/engineering/pure_fp_standards.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Formalize the at-least-once event-processing pattern from
[streaming_doctrine.md#at-least-once-event-processing](../documents/engineering/streaming_doctrine.md#at-least-once-event-processing)so the gateway commit log and any future
daemon event-consuming surface (workload runtime, future workers) share one canonical
module rather than ad-hoc per-call-site patterns. Sprint 2.13 already names at-least-once
formalization on the commit log; this sprint owns the module that backs it.

### Deliverables

- New module `src/Prodbox/Daemon/Events.hs` exposing:
  - `data StoredEvent = StoredEvent { eventId :: EventId, eventAggregateId :: AggregateId,
    eventType :: EventType, eventPayload :: Aeson.Value, eventCreatedAt :: UTCTime,
    eventProcessedAt :: Maybe UTCTime }` matching doctrine §1653–1660.
  - `newtype EventHandler = EventHandler (StoredEvent -> IO ())` with the idempotency
    precondition encoded in the haddock comment per doctrine §1720.
  - `recordEvent`, `markEventProcessed`, `fetchUnprocessedEvents`, and a top-level
    `processEvents` consumer that fetches unprocessed events, invokes the handler, marks each
    `processed_at`, and returns the count processed.
- `src/Prodbox/Gateway/Daemon.hs` peer-event ingestion in `peerListenerLoop` consumes the
  new module (or records in `documents/engineering/distributed_gateway_architecture.md`
  why the gateway intentionally uses the in-memory peer-gossip variant rather than the
  database-backed `processed_at` form; both options are doctrine-legal, the outcome is
  recorded in this sprint's deliverables and propagated to the doctrine correspondence
  notes).
- `documents/engineering/pure_fp_standards.md` cross-references
  `src/Prodbox/Daemon/Events.hs` as the canonical at-least-once pattern for any future
  daemon event-consumer.
- Enqueue any pre-doctrine event-processing call site under `src/Prodbox/Gateway/` or
  `src/Prodbox/Workload.hs` that does not consume the new module in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending Removal`
  with Sprint 2.16 as owner.

### Validation

1. `cabal test prodbox-unit` covers the `recordEvent` / `markEventProcessed` /
   `fetchUnprocessedEvents` triad against a deterministic clock test hook (Sprint 2.13).
2. A property test asserts that running `processEvents` twice in a row over the same set
   of unprocessed events is a no-op on the second invocation (idempotent-replay
   contract).
3. The `documents/engineering/distributed_gateway_architecture.md` correspondence section
   names whether the gateway commit log adopts the module or intentionally keeps the
   in-memory variant, with explicit doctrine-citation either way.

### Current Validation State

- `src/Prodbox/Daemon/Events.hs` exposes `StoredEvent`, `EventId`, `AggregateId`,
  `EventType`, `EventHandler`, `recordEvent`, `markEventProcessed`,
  `fetchUnprocessedEvents`, and `processEvents` over a deterministic in-memory `EventStore`.
- `prodbox-unit` covers event recording, duplicate suppression by event id, processed-state
  filtering, chronological replay, and idempotent second `processEvents` runs.
- `documents/engineering/distributed_gateway_architecture.md` records that the gateway commit log
  intentionally remains the in-memory anti-entropy peer-gossip variant while future durable event
  consumers use `Prodbox.Daemon.Events`.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - Haskell gateway command surface, including the
  distinct native `gateway-partition` validation contract.
- `documents/engineering/dependency_management.md` - gateway container-build posture under the
  canonical Docker doctrine, including the `ghcup` pin and no-symlink rule.
- `documents/engineering/distributed_gateway_architecture.md` - Haskell gateway implementation,
  retained DNS ownership doctrine, and the authoritative peer-transport plus REST surface.
- `documents/engineering/local_registry_pipeline.md` - gateway-container build, Harbor loading, and
  native-host-architecture delivery doctrine.
- `documents/engineering/tla/README.md` - formal model entrypoint and execution contract.
- `documents/engineering/tla_modelling_assumptions.md` - correspondence between the Haskell runtime
  and the model, including the split between native partition validation and `tla-check`.
- `documents/engineering/unit_testing_policy.md` - Haskell gateway integration-suite ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep gateway and TLA+ doctrine linked back to [README.md](README.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
