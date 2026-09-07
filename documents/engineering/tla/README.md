# TLA+ Models

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Index TLA+ models for prodbox correctness properties.

---

## Scope Notes

This index owns model discovery only.

Current model-to-runtime correspondence, known divergences, and verification boundaries are owned
by [TLA+ Modelling Assumptions](../tla_modelling_assumptions.md).

Sprint sequencing, closure status, remaining work, and cleanup ownership for the TLA surface are
owned by [DEVELOPMENT_PLAN/README.md](../../../DEVELOPMENT_PLAN/README.md).

---

## Models

| Model | Purpose |
|-------|---------|
| [gateway_orders_rule.tla](./gateway_orders_rule.tla) | Orders-driven gateway ownership rule model |
| [gateway_orders_rule.cfg](./gateway_orders_rule.cfg) | TLC model configuration for `gateway_orders_rule.tla` |
| [gateway_legacy_liveness.tla](./gateway_legacy_liveness.tla) | Pre-cutover durable-fence rotation, compacted-cursor witness, and signed latest-only liveness model |
| [gateway_legacy_liveness.cfg](./gateway_legacy_liveness.cfg) | TLC model configuration for `gateway_legacy_liveness.tla` |

---

## Notes

- The journal/Lease model is peer-to-peer and has no centralized lease store.
- Rule determinism and singleton takeover are explicit properties.
- Split-brain freedom depends on model assumptions about view convergence.
- The legacy-liveness model is a separate pre-cutover refinement; it does not weaken or replace the
  target journal/Lease model.

## Running Checks

- TLA+ must be executed in Docker via `maxdiefenbach/tlaplus`.
- `src/Prodbox/Tla.hs` owns the public `prodbox dev tla-check` entrypoint.
- CLI command: `prodbox dev tla-check`.
- The command invokes one self-deleting container per registered model and stores their combined
  latest result at `documents/engineering/tla/tlc_last_run.txt`.
