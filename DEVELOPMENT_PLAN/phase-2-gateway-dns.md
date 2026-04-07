# File: DEVELOPMENT_PLAN/phase-2-gateway-dns.md
# Phase 2: Distributed Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the distributed gateway runtime, its formal verification path, and the
> canonical Route 53 ownership/update flow.

## Phase Summary

This phase ships the managed gateway CLI surface, the distributed runtime implementation, the TLA+
entrypoint, and the gateway-owned Route 53 write capability for explicit named public records that
later cleanup and public-host phases depend on.

## Sprint 2.1: Distributed Gateway Runtime, Formal Verification, and DNS-Write Capability ✅

**Status**: Done
**Implementation**: `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/tla.py`, `src/prodbox/tla_check.py`, `tests/integration/test_gateway_daemon_k8s.py`, `tests/integration/test_gateway_k8s_pods.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Ship the distributed gateway daemon, its managed CLI surface, the formal verification entrypoint,
and the gateway Route 53 write capability.

### Deliverables

- `prodbox gateway start|status|config-gen|install-service` exists as the managed CLI surface.
- Process-mode and pod-backed gateway behavior are both validated.
- TLA+ model checking is exposed through `prodbox tla-check`.
- The gateway runtime supports Route 53 writes through `dns_write_gate`.
- The supported DNS ownership model uses explicit named records, not wildcard public DNS.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration gateway-daemon`
4. `poetry run prodbox test integration gateway-pods`
5. `poetry run prodbox tla-check`

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - managed gateway command surface.
- `documents/engineering/distributed_gateway_architecture.md` - runtime design and DNS ownership.
- `documents/engineering/tla/README.md` - formal model index and invocation path.
- `documents/engineering/tla_modelling_assumptions.md` - code/model correspondence.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep gateway and TLA+ doctrine linked back to `DEVELOPMENT_PLAN/README.md`.
