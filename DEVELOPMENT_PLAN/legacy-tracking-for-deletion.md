# Legacy Tracking

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Track every known Python-removal item, compatibility helper, duplicate surface, and
> stale tooling residue that still needs deletion outside the declarative phase narrative.

> **Authoritative Reference**: [development_plan_standards.md](development_plan_standards.md#i-explicit-cleanup-and-removal-ledger)

## Reopened Ledger Baseline

As of April 16, 2026, the previous Python-era clean-room ledger is reopened because the repository
handoff target has changed. The old Python implementation is no longer the supported end state, so
Python source, Python toolchain ownership, and Python Pulumi programs are now explicit removal
items rather than invisible background context.

## Pending Removal

| Item | Owned By | Notes |
|------|----------|-------|
| `src/prodbox/**/*.py` Python implementation modules | Sprint 4.3 | Remove after Haskell parity exists for the same supported surfaces |
| `tests/**/*.py` Python unit and integration harnesses | Sprint 4.3 | Replace with Haskell-owned unit and integration suites before deletion |
| `typings/` Python type-stub inventory | Sprint 4.3 | Remove once Python runtime and mypy ownership are gone |
| `pyproject.toml`, `poetry.lock`, `.python-version` | Sprint 4.3 | Python packaging and Poetry ownership must not survive final handoff |
| Python-specific quality-tool ownership under `prodbox check-code` | Sprint 4.3 | Replace `ruff`, `mypy`, and Python-oriented check orchestration with Haskell-owned tooling |
| Python Pulumi programs under `src/prodbox/infra/` and `pulumi/` | Sprint 4.2 | Replace with non-Python Pulumi definitions while retaining `prodbox pulumi ...` as the public surface |
| Python CLI entrypoint and interpreter ownership | Sprint 1.1 | Replace Click and interpreter ownership with Haskell CLI modules and ADTs |
| Python settings or config-loading path | Sprint 1.2 | Replace Pydantic-based settings ownership with Haskell Dhall decoding |
| Python gateway runtime and container entrypoint | Sprint 2.1 | Replace with Haskell gateway binary and in-cluster packaging |
| Python chart orchestration and retained-state helpers | Sprint 3.1 | Replace with Haskell chart platform modules |
| Python public-edge diagnostic helpers | Sprint 5.1 | Replace with Haskell `prodbox host public-edge` implementation |
| Python onboarding, IAM, quota, and `aws_admin` helpers | Sprint 7.1, Sprint 7.2, Sprint 7.3 | Remove once the Haskell onboarding and AWS admin surfaces close |
| Root and doctrine docs that still present Python as supported architecture | Sprint 6.2 | Remove or rewrite every surviving Python-as-canonical statement before final handoff |
| Any surviving file search hits for `poetry`, `pytest`, `mypy`, `ruff`, `click`, `pydantic`, or `python` that describe current supported architecture | Sprint 6.2 | Final cleanup sweep after implementation closure |

## Completed

| Item | Removed In | Notes |
|------|------------|-------|
| Python-era clean-room backlog through April 15, 2026 | Pre-rewrite baseline | Closed before the Haskell rewrite reopened this ledger on April 16, 2026 |

## Related Documents

- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
