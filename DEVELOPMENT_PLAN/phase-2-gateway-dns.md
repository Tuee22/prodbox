# Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell gateway runtime, its formal verification path, and the
> canonical Route 53 ownership or update flow.

## Phase Summary

This phase ports the gateway daemon, DNS inspection command, and related command surfaces to
Haskell, preserves the formal model entrypoint, and keeps Route 53 write ownership inside the
in-cluster gateway workload. The gateway runtime and DNS ownership remain closed on the Haskell
stack. Sprint `2.1` is now done: the gateway image packaging and Harbor-backed dual-arch delivery
contract are implemented in the worktree, the host linker prerequisite is cleared, and the named
gateway validation surfaces have rerun successfully on the updated implementation.

## Current Baseline In Worktree

- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` entry
  surfaces. `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` and `src/Prodbox/Gateway/Types.hs`. All Python gateway code has
  been removed.
- The gateway container build lives in `docker/gateway.Dockerfile` and now uses the canonical
  single-stage `ubuntu:24.04` doctrine while mounting the official `haskell:9.6.7-slim`
  toolchain image as a BuildKit context during publication and installing the official AWS CLI
  bundle per `TARGETARCH`.
- The in-cluster gateway steady state is repo-rootless: `app/prodbox/Main.hs` now permits
  repo-rootless `gateway start|status`, and `charts/gateway/` injects AWS credentials through the
  `gateway-aws-credentials` secret while probing `/v1/state` over HTTP on the in-pod REST port.
- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface. All Python DNS wrappers have
  been removed.
- `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` surface. All Python TLA+ wrappers have
  been removed.
- Gateway and TLA+ proof live in the Haskell test suites under `test/`.
- `src/Prodbox/TestPlan.hs` maps the gateway validation names to executable native validations in
  `src/Prodbox/TestValidation.hs`.
- The canonical host-side build, doctrine gate, and Phase `1` validation reruns now pass on this
  host after restoring the missing ncurses development linker dependency.

## Sprint 2.1: Haskell Gateway Runtime and Command Surface ✅

**Status**: Done
**Implementation**: `src/Prodbox/Dns.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `charts/gateway/`, `docker/gateway.Dockerfile`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Replace the Python gateway daemon, DNS inspection command, and gateway-adjacent CLI surfaces with
Haskell while preserving runtime behavior and aligning the gateway image with the canonical
container doctrine.

### Deliverables

- `prodbox gateway start|status|config-gen` and `prodbox dns check` are implemented in Haskell.
- The in-cluster gateway container runs the Haskell binary from a single-stage `ubuntu:24.04`
  image built from `docker/gateway.Dockerfile`.
- Gateway image delivery uses Harbor as the only supported cluster image source.
- Gateway image publication produces or loads both `amd64` and `arm64` variants irrespective of
  the operator host architecture.
- Gateway event-key continuity and state inspection move to Haskell-owned modules.
- The target steady state remains the in-cluster gateway workload; no host-side daemon is revived.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox dns check`
4. `prodbox test integration gateway-daemon`
5. `prodbox test integration gateway-pods`
6. Gateway image proof: `docker/gateway.Dockerfile` is single-stage `ubuntu:24.04`
7. Harbor proof: the gateway image is available from Harbor for both `amd64` and `arm64`

### Current Validation State

- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface and preserves the
  inspection-only output contract against the repository Dhall settings plus Route 53.
- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` surfaces;
  `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` using `runGatewayDaemon`.
- `src/Prodbox/Gateway/Types.hs` provides core gateway types: `PeerEndpoint`, `GatewayRule`,
  `Orders`, `SignedEvent`, `CommitLog`, `DaemonConfig`, `DnsWriteGate`, and config parsing.
- `src/Prodbox/Gateway/Daemon.hs` provides the daemon runtime: heartbeat loop, gateway ownership
  loop, DNS write loop, REST server, and HMAC event signing.
- `test/unit/Main.hs` proves parser routing plus renderer and template behavior for native
  `dns check`, `gateway start`, `gateway status`, and `gateway config-gen`, and
  `test/integration/cli/Main.hs` proves the built frontend for native `gateway status` and
  `gateway config-gen` plus native error handling for `gateway start`.
- The named validation commands in this sprint (`prodbox test integration gateway-daemon` and
  `prodbox test integration gateway-pods`) run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.
- `docker/gateway.Dockerfile` is now single-stage `ubuntu:24.04`.
- `docker/gateway.Dockerfile` now installs the official AWS CLI bundle per `TARGETARCH` so the
  daemon's `aws route53 ...` subprocess path remains available inside the runtime image without
  abandoning the single-stage `ubuntu:24.04` doctrine.
- `src/Prodbox/CLI/Rke2.hs` now publishes the gateway image through the supported Harbor-backed
  per-platform `buildx` flow, composes the final multi-arch manifest with
  `docker buildx imagetools create`, creates the buildx builder with host networking so pushes to
  `127.0.0.1:30080` succeed from inside the builder container, and re-imports the
  host-architecture variant for RKE2.
- `src/Prodbox/Lib/ChartPlatform.hs` resolves the supported gateway chart image through Harbor.
- `charts/gateway/` now keeps the pod contract repo-rootless by removing the stale
  `prodbox-config.json` mount, rendering the `gateway-aws-credentials` secret, wiring AWS auth
  through env vars, and probing the daemon's `/v1/state` health endpoint over HTTP.
- The host linker prerequisite is cleared, and `./.build/prodbox dns check`,
  `./.build/prodbox test integration gateway-daemon`, and
  `./.build/prodbox test integration gateway-pods` now pass on this host, re-closing validation
  items `3-7` on the updated gateway packaging path.

### Remaining Work

None.

## Sprint 2.2: Formal Verification and DNS-Write Ownership Parity ✅

**Status**: Done
**Implementation**: `src/Prodbox/Tla.hs`, `documents/engineering/tla/`, `test/unit/Main.hs`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Retain the formal verification and single-writer DNS ownership guarantees after the gateway port.

### Deliverables

- `prodbox tla-check` remains part of the supported validation surface.
- Gateway config generation still emits `dns_write_gate` for explicit public hostnames.
- Route 53 write ownership remains single-writer under leader election.
- Partition-heal and failover behavior are re-proved on the Haskell gateway.

### Validation

1. `prodbox tla-check`
2. `prodbox test integration gateway-partition`
3. `prodbox test integration gateway-pods`

### Current Validation State

- `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` surface and preserves the Docker-backed
  TLC workflow plus `documents/engineering/tla/tlc_last_run.txt` result persistence.
- `test/unit/Main.hs` proves parser routing for native `tla-check`.
- Native Haskell `gateway config-gen` preserves `dns_write_gate` emission. All Python TLA+ and
  gateway wrappers have been removed. The Haskell gateway daemon runtime owns partition-heal and
  failover behavior.
- `src/Prodbox/TestPlan.hs` maps `prodbox test integration gateway-partition` to an executable
  native validation flow in `src/Prodbox/TestValidation.hs`.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - Haskell gateway command surface.
- `documents/engineering/dependency_management.md` - gateway container-build posture under the
  canonical Docker doctrine.
- `documents/engineering/distributed_gateway_architecture.md` - Haskell gateway implementation and
  retained DNS ownership doctrine.
- `documents/engineering/local_registry_pipeline.md` - gateway-container build, Harbor loading, and
  dual-arch delivery doctrine.
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
