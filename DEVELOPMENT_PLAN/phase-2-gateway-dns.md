# Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell gateway runtime, its formal verification path, and the canonical
> Route 53 ownership or update flow.

## Phase Summary

This phase ports the gateway daemon and its command surface to Haskell, preserves the formal model
entrypoint, and keeps Route 53 write ownership inside the in-cluster gateway workload. The target
steady state remains inside the RKE2 cluster as a Kubernetes workload rather than a host daemon.

## Sprint 2.1: Haskell Gateway Runtime and Command Surface 📋

**Status**: Planned
**Implementation**: `src/Prodbox/Gateway/`, `src/Prodbox/CLI/Gateway.hs`, `charts/gateway/`, `test/unit/gateway/`, `test/integration/gateway/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Replace the Python gateway daemon and gateway CLI surfaces with Haskell while preserving runtime
behavior.

### Deliverables

- `prodbox gateway start|status|config-gen` are implemented in Haskell.
- The in-cluster gateway container runs the Haskell binary.
- Gateway event-key continuity and state inspection move to Haskell-owned modules.
- The target steady state remains the in-cluster gateway workload; no host-side daemon is revived.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-pods`

### Remaining Work

- All deliverables remain open.

## Sprint 2.2: Formal Verification and DNS-Write Ownership Parity 📋

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Tla.hs`, `documents/engineering/tla/`, `test/integration/gateway/`
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

### Remaining Work

- All deliverables remain open.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - Haskell gateway command surface.
- `documents/engineering/distributed_gateway_architecture.md` - Haskell gateway implementation and
  retained DNS ownership doctrine.
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
