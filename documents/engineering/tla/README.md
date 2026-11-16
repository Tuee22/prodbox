# Existing Formal Models

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Index of unchanged source artifacts; no new target qualification is claimed.

> **Purpose**: Locate current TLA+ artifacts and their declared validation boundary.

| Artifact | Scope |
|---|---|
| [gateway_orders_rule.tla](gateway_orders_rule.tla) and [configuration](gateway_orders_rule.cfg) | Finite gateway Orders ownership rule |
| [gateway_legacy_liveness.tla](gateway_legacy_liveness.tla) and [configuration](gateway_legacy_liveness.cfg) | Pre-cutover continuity/liveness model; historical assumptions require review |
| [lifecycle_create_ownership.tla](lifecycle_create_ownership.tla) and [configuration](lifecycle_create_ownership.cfg) | Write-ahead resource identity versus create/crash/recovery |
| [Superseded-order configuration](lifecycle_create_ownership_superseded.cfg) | Expected counterexample control for the broken create ordering |

[Formal correspondence](../tla_modelling_assumptions.md) owns assumptions and claim limits. `src/Prodbox/Tla.hs` still owns actual runner/registration; this adoption changes no model or configuration. The existing `prodbox dev tla-check` remains subject to actual binary help and prerequisites. Do not infer a successful model run or current deployment proof from this index.

Phase 9 owns retained runtime correspondence and L17 retirements; Phase 0 owns checker/link adoption. [Resume Here](../../../DEVELOPMENT_PLAN/README.md#resume-here)
