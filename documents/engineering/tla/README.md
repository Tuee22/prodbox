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
| [lifecycle_create_ownership.tla](./lifecycle_create_ownership.tla) | Admit/create/crash/restart/reconcile ownership model: no provider effect lands without a durable record naming its coordinates |
| [lifecycle_create_ownership.cfg](./lifecycle_create_ownership.cfg) | TLC model configuration for `lifecycle_create_ownership.tla` under the write-ahead ordering; expected to find no counterexample |
| [lifecycle_create_ownership_superseded.cfg](./lifecycle_create_ownership_superseded.cfg) | The frozen superseded ordering of the same module; **expected to produce a counterexample**, so the surface is shown to be able to fail |

---

## Notes

- `Prodbox.Tla.tlaModels` is the registry, and `checkTlaModelRegistration` holds this directory
  against it in both directions: a `.tla` or `.cfg` file nobody registers fails `prodbox dev check`,
  and a registry entry with no file fails it too. An unregistered model is a proof surface that does
  not run.
- Each registered entry declares the disposition TLC must report. A model checked only in the
  configuration it passes under has been observed to pass and never to refuse, so at least one
  registered configuration must expect a counterexample; that is also gated.
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
  latest result at `documents/engineering/tla/tlc_last_run.txt`, including each run's declared
  expectation and whether it was satisfied.
- TLC runs with `-cleanup` and `-noGenerateSpecTE`, because a configuration that is expected to
  produce a counterexample would otherwise leave a trace-expression module and a root-owned `states`
  directory inside a governed directory.
