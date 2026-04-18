# Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell gateway runtime, its formal verification path, and the canonical
> Route 53 ownership or update flow.

## Phase Summary

This phase ports the gateway daemon, DNS inspection command, and related command surfaces to
Haskell, preserves the formal model entrypoint, and keeps Route 53 write ownership inside the
in-cluster gateway workload. The target steady state remains inside the RKE2 cluster as a
Kubernetes workload rather than a host daemon.

## Current Baseline In Worktree

- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` entry
  surfaces. `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` and `src/Prodbox/Gateway/Types.hs`. All Python gateway code
  has been removed.
- The gateway container (`docker/gateway.Dockerfile`) now builds a Haskell binary using a
  multi-stage build with `haskell:9.6.7` builder and `debian:bookworm-slim` runtime.
- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface. All Python DNS wrappers have
  been removed.
- `src/Prodbox/Tla.hs` owns the public `prodbox tla-check` surface. All Python TLA+ wrappers
  have been removed.
- Gateway and TLA+ proof lives in the Haskell test suites under `test/`.

## Sprint 2.1: Haskell Gateway Runtime and Command Surface ✅

**Status**: Done
**Implementation**: `src/Prodbox/Dns.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `charts/gateway/`, `docker/gateway.Dockerfile`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Replace the Python gateway daemon, DNS inspection command, and gateway-adjacent CLI surfaces
with Haskell while preserving runtime behavior.

### Deliverables

- `prodbox gateway start|status|config-gen` and `prodbox dns check` are implemented in Haskell.
- The in-cluster gateway container runs the Haskell binary.
- Gateway image delivery continues through the retained local-registry pipeline rather than
  reviving a direct host-binary steady state.
- Gateway event-key continuity and state inspection move to Haskell-owned modules.
- The target steady state remains the in-cluster gateway workload; no host-side daemon is revived.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox dns check`
4. `prodbox test integration gateway-daemon`
5. `prodbox test integration gateway-pods`

### Current Validation State

- `src/Prodbox/Dns.hs` now owns the public `prodbox dns check` surface and preserves the
  inspection-only output contract against the repository Dhall settings plus Route 53.
- `src/Prodbox/Gateway.hs` now owns the public `prodbox gateway start|status|config-gen` surfaces;
  `gateway start` now runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` using `runGatewayDaemon` instead of delegating to the Python
  backend.
- `src/Prodbox/Gateway/Types.hs` provides core gateway types: `PeerEndpoint`, `GatewayRule`,
  `Orders`, `SignedEvent`, `CommitLog`, `DaemonConfig`, `DnsWriteGate`, and config parsing.
- `src/Prodbox/Gateway/Daemon.hs` provides the daemon runtime: heartbeat loop, gateway ownership
  loop, DNS write loop, REST server, and HMAC event signing.
- New dependencies added to `prodbox.cabal`: `async`, `cryptohash-sha256`, `network`, `stm`,
  `time`, `tls`, `x509`, `x509-store`.
- `test/unit/Main.hs` now proves parser routing plus renderer and template behavior for native
  `dns check`, `gateway start`, `gateway status`, and `gateway config-gen`, and
  `test/integration/cli/Main.hs` now proves the built frontend for native `gateway status` and
  `gateway config-gen` plus native error handling (graceful failure on missing config) for
  `gateway start`.
- `prodbox test unit` passes after the native gateway daemon lands, and
  `test/integration/cli/Main.hs` now provides the built-frontend CLI proof for the gateway command
  family.
- All Python gateway code has been removed. The gateway Dockerfile now builds a Haskell binary.
- The named validation commands in this sprint (`prodbox test integration gateway-daemon` and
  `prodbox test integration gateway-pods`) now run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.

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

- `src/Prodbox/Tla.hs` now owns the public `prodbox tla-check` surface and preserves the
  Docker-backed TLC workflow plus `documents/engineering/tla/tlc_last_run.txt` result persistence.
- `test/unit/Main.hs` proves parser routing for native `tla-check`, and `prodbox test unit`
  passes after the Haskell wrapper lands.
- Native Haskell `gateway config-gen` preserves `dns_write_gate` emission. All Python TLA+ and
  gateway wrappers have been removed. The Haskell gateway daemon runtime now owns partition-heal
  and failover behavior.
- The named validation command `prodbox test integration gateway-partition` remains modeled as a
  pending native payload in `src/Prodbox/TestPlan.hs`; it now depends on reopened Sprint `1.2`
  harness closure and is not counted as part of today's passing local proof.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - Haskell gateway command surface.
- `documents/engineering/distributed_gateway_architecture.md` - Haskell gateway implementation and
  retained DNS ownership doctrine.
- `documents/engineering/local_registry_pipeline.md` - gateway-container build and delivery
  doctrine after the Python daemon entrypoint is removed.
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
