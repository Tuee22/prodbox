# TLA+ Models

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: documents/engineering/distributed_gateway_architecture.md, documents/engineering/README.md

> **Purpose**: Index TLA+ models for prodbox correctness properties.

---

## Models

| Model | Purpose |
|-------|---------|
| [gateway_lease.tla](./gateway_lease.tla) | Lease ownership and gateway leadership safety |
| [gateway_lease.cfg](./gateway_lease.cfg) | TLC model configuration for `gateway_lease.tla` |

---

## Notes

- The gateway model proves lease-level mutual exclusion and epoch monotonicity.
- Route 53 is modeled as a projection (`dnsOwner`, `dnsEpoch`) rather than the source of truth.
