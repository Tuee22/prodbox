# TLA+ Models

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: documents/engineering/distributed_gateway_architecture.md, documents/engineering/README.md

> **Purpose**: Index TLA+ models for prodbox correctness properties.

---

## Models

| Model | Purpose |
|-------|---------|
| [gateway_orders_rule.tla](./gateway_orders_rule.tla) | Orders-driven gateway ownership rule model |
| [gateway_orders_rule.cfg](./gateway_orders_rule.cfg) | TLC model configuration for `gateway_orders_rule.tla` |

---

## Notes

- The model is peer-to-peer and has no centralized lease store.
- Rule determinism and singleton takeover are explicit properties.
- Split-brain freedom depends on model assumptions about view convergence.

## Running Checks

- TLA+ must be executed in Docker via `tlaplatform/tlaplus`.
- CLI command: `poetry run prodbox tla-check`.
- The command invokes `docker run --rm ...` and stores the latest result at `documents/engineering/tla/tlc_last_run.txt`.
