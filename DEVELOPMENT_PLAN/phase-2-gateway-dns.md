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
the gateway workload, DNS inspection, and the TLA+ entrypoint. The phase-owned repository
surfaces are closed on the daemon, `prodbox gateway status`, the implemented HTTP `/v1/state`
payload, Orders-backed interval validation, and the runtime-to-model correspondence notes. The
gateway container doctrine is implemented on `ubuntu:24.04` with in-image `ghcup`, pinned GHC
`9.14.1`, no symlinked Haskell tool shims, and the retained in-image AWS CLI bundle. The current
daemon surface implements config generation, heartbeat recording, in-memory ownership projection,
DNS-write gating, HTTP REST status, and HMAC event signing. The broader peer-transport protocol
remains design-owned by the TLA+ and gateway doctrine docs rather than by a closed repository
surface. Sprints `2.1` and `2.2` remain closed on the gateway-daemon and TLA+ baseline. Sprint
`2.3` is active because the supported DNS doctrine now changes from explicit per-FQDN public-host
ownership to one canonical public record: `test.resolvefintech.com`. This phase does not own the
Kubernetes Gateway API or Envoy Gateway public edge; those surfaces remain in Phases `1`, `3`,
`4`, and `5`.

## Current Baseline In Worktree

- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` entry
  surfaces. `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` and `src/Prodbox/Gateway/Types.hs`. All Python gateway code has
  been removed.
- The gateway container build lives in `docker/gateway.Dockerfile`, is single-stage
  `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, retains the official AWS CLI
  bundle per `TARGETARCH`, and does not depend on the old mounted `haskell:9.6.7-slim` toolchain
  context or symlinked GHC tool shims.
- The in-cluster gateway steady state is repo-rootless: `app/prodbox/Main.hs` now permits
  repo-rootless `gateway start|status`, and `charts/gateway/` injects AWS credentials through the
  `gateway-aws-credentials` secret while probing `/v1/state` over HTTP on the in-pod REST port.
- `src/Prodbox/Gateway.hs` now queries daemon state over the governed HTTP `/v1/state`
  observability surface, matching the chart probes and the in-pod REST listener in
  `src/Prodbox/Gateway/Daemon.hs`.
- `src/Prodbox/Gateway/Daemon.hs` now renders the documented `/v1/state` payload fields used for
  operator and integration observability, including `event_hashes` and `heartbeat_age_seconds`.
- `src/Prodbox/Gateway/Types.hs` now enforces the documented cross-field interval relationships
  from `documents/engineering/distributed_gateway_architecture.md` against the Orders timeout.
- `src/Prodbox/Gateway/Types.hs` still parses certificate, key, CA, and socket metadata in the
  daemon config and Orders document, but the current closed runtime surface does not materialize
  peer transport from those fields.
- The Haskell `prodbox gateway ...` surface remains distinct from the Envoy Gateway public edge
  surface.
- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface. All Python DNS wrappers have
  been removed.
- `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` surface. All Python TLA+ wrappers have
  been removed.
- The current DNS surfaces still assume explicit public hostnames. Sprint `2.3` retargets that
  ownership to the one-record doctrine without changing the separate Haskell gateway-daemon
  boundary.
- Gateway parser, renderer, and CLI proof live in the Haskell test suites under `test/`, while
  the TLA+ artifacts live under `documents/engineering/tla/` and are exercised through
  `prodbox tla-check`.
- `src/Prodbox/TestPlan.hs` maps the gateway validation names to executable native validations in
  `src/Prodbox/TestValidation.hs`.
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
  no symlinked Haskell tool shims, and the official AWS CLI bundle per `TARGETARCH`.
- Gateway image delivery uses Harbor as the only supported cluster image source.
- Gateway image publication follows the lifecycle-owned native-host-architecture doctrine:
  `amd64` hosts publish `amd64` images, and `arm64` hosts publish `arm64` images.
- Gateway event-key continuity and state inspection move to Haskell-owned modules.
- The daemon and `prodbox gateway status` close on the implemented HTTP `/v1/state`
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
  model even though the closed runtime surface uses the REST listener and local daemon loops only.
- `src/Prodbox/Gateway/Daemon.hs` provides the daemon runtime: heartbeat loop, gateway ownership
  loop, DNS write loop, HTTP REST server, and HMAC event signing. The state payload now exposes
  `event_hashes`, `heartbeat_age_seconds`, and the DNS-write observability fields described by the
  gateway doctrine.
- `src/Prodbox/Gateway.hs` now dials daemon state over the same HTTP `/v1/state` endpoint used by
  the in-cluster liveness and readiness probes, so the public status path and the daemon listener
  close on one native transport contract.
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
- `docker/gateway.Dockerfile` already installs the official AWS CLI bundle per `TARGETARCH`; that
  requirement stays in place after the toolchain doctrine changes.
- `src/Prodbox/CLI/Rke2.hs` still publishes the gateway image through a Harbor-backed cross-arch
  `docker buildx` flow with no mounted `haskell-toolchain` context, but that publication path is
  now legacy cleanup owned by reopened Sprint `4.1`; this sprint remains closed on the gateway
  runtime, CLI, and container structure.
- `src/Prodbox/Lib/ChartPlatform.hs` resolves the supported gateway chart image through Harbor.
- `charts/gateway/` now keeps the pod contract repo-rootless by removing the stale
  `prodbox-config.json` mount, rendering the `gateway-aws-credentials` secret, wiring AWS auth
  through env vars, and probing the daemon's `/v1/state` health endpoint over HTTP.
### Remaining Work

None.

## Sprint 2.3: Single-Record Route 53 Ownership and Diagnostics 🔄

**Status**: Active
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

- `src/Prodbox/Dns.hs` and native validation flows still reason about the current multi-host Route
  53 surface.
- Native Haskell `gateway config-gen` still preserves `dns_write_gate` emission, but that payload
  remains shaped around explicit public hostnames rather than the single supported record.
- The TLA+ correspondence notes still describe the current write-ownership model rather than the
  new one-record doctrine.

### Remaining Work

- Replace the per-FQDN DNS inventory with one canonical `test.resolvefintech.com` ownership model.
- Update DNS diagnostics and validations to reject placeholder domains and multi-host public-edge
  config.
- Align the gateway or TLA+ correspondence docs with the single-record Route 53 doctrine.

## Sprint 2.2: Formal Verification Entrypoint and DNS-Write-Gate Contract ✅

**Status**: Done
**Implementation**: `src/Prodbox/Tla.hs`, `documents/engineering/tla/`, `test/unit/Main.hs`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`

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
- `src/Prodbox/TestPlan.hs` maps `prodbox test integration gateway-partition` to the Haskell
  `tla-check` validation surface through `src/Prodbox/TestValidation.hs`.
### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - Haskell gateway command surface.
- `documents/engineering/dependency_management.md` - gateway container-build posture under the
  canonical Docker doctrine, including the `ghcup` pin and no-symlink rule.
- `documents/engineering/distributed_gateway_architecture.md` - Haskell gateway implementation and
  retained DNS ownership doctrine.
- `documents/engineering/local_registry_pipeline.md` - gateway-container build, Harbor loading, and
  native-host-architecture delivery doctrine.
- `documents/engineering/tla/README.md` - formal model entrypoint and execution contract.
- `documents/engineering/tla_modelling_assumptions.md` - correspondence between the Haskell runtime
  and the model.
- `documents/engineering/unit_testing_policy.md` - Haskell gateway integration-suite ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep gateway and TLA+ doctrine linked back to [README.md](README.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
