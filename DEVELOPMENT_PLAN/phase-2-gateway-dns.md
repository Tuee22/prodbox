# Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md)

> **Purpose**: Capture the Haskell gateway runtime, its formal verification path, and the
> canonical Route 53 ownership or update flow.

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
**Implementation**: `src/Prodbox/Dns.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `charts/gateway/`, `docker/gateway.Dockerfile`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
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
  `test/integration/cli/Main.hs` proves the built frontend for native `gateway status` and
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
