# File: DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md
# Phase 6: Final Clean-Room Rerun and Zero-Legacy Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the final repository handoff criteria: a full clean-room rerun through
> canonical entrypoints only and an empty remaining legacy inventory.

## Phase Summary

This phase reruns the authoritative validation set from the supported operator flow after the
public-host and AWS cleanup proofs close. The repository hands off only when no sprint remains
blocked or active and the cleanup ledger is empty. That final handoff proof is now complete:
Sprint 6.2 reran the clean-room path from both required clean states, restored the supported
runtime without manual intervention, and re-proved zero AWS residue through the aggregate harness
flow.

## Sprint 6.1: Final Clean-Room Validation Rerun and Zero-Legacy Handoff ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/infra/cert_manager.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/metallb.py`, `tests/unit/test_infra_program.py`, `tests/unit/test_test_cmd.py`, `documents/engineering/cli_command_surface.md`, `documents/engineering/unit_testing_policy.md`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Rerun the authoritative validation set from a clean operator flow and hand off a repository with no
remaining compatibility backlog.

### Deliverables

- Every remaining blocked sprint closes.
- The clean-room validation set reruns through canonical entrypoints only.
- Docs under `documents/` remain doctrine-only and defer status tracking to this plan suite.
- The remaining legacy inventory is empty.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration all`
4. `poetry run prodbox tla-check`
5. `poetry run prodbox test integration public-dns`

### Current Validation State

- The legacy ledger Pending Removal section remains empty.
- `poetry run prodbox check-code` passed on April 12, 2026.
- `poetry run prodbox test unit` passed on April 12, 2026 (982 tests).
- `poetry run prodbox test integration public-dns` passed on April 12, 2026 (2 tests).
- `prodbox host public-edge` reports `CLASSIFICATION=ready-for-external-proof`.
- `poetry run prodbox test integration charts-vscode` passed on April 12, 2026 (8 tests).
- `poetry run prodbox test integration all` passed on April 12, 2026.
- `poetry run prodbox tla-check` passed on April 12, 2026.
- `poetry run prodbox test all` completed cleanly on April 12, 2026 after postflight runtime
  restore returned `prodbox host public-edge` to
  `CLASSIFICATION=ready-for-external-proof`.
- Aggregate suites now run `test_charts_platform.py` before `test_charts_storage.py`, restore the
  supported runtime with `prodbox pulumi refresh`, `prodbox pulumi up --yes`,
  `prodbox charts deploy gateway`, and `prodbox charts deploy vscode` after the destructive pytest
  tail, and then re-check
  `prodbox host public-edge` before exit. Pulumi-managed MetalLB, Traefik, and cert-manager
  releases also use stable Helm release names so the supported clean-room recreate path can
  reattach cluster-scoped objects without hashed-release drift.

### Remaining Work

None.

## Sprint 6.2: Clean-Cluster Aggregate Bootstrap and Zero-AWS-Residue Closure ✅

**Status**: Done
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `tests/unit/test_settings.py`, `tests/integration/test_cli_env.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/aws_helpers.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the aggregate validation path self-healing from a completely cleaned RKE2 cluster and a
repository state without a precompiled `prodbox-config.json`, then prove that the same rerun
leaves no fixture-owned AWS resources behind through the supported test harness rather than a
standalone janitor surface.

### Deliverables

- Starting from `poetry run prodbox rke2 cleanup --yes` and a repository state without a
  precompiled `prodbox-config.json`, the supported aggregate rerun path restores MetalLB,
  Traefik, cert-manager, the issuer/bootstrap layer, the in-cluster gateway, and the `vscode`
  stack without manual operator repair.
- The aggregate suite no longer calls the public-edge readiness gate before the Pulumi-managed
  edge stack exists, and the restore path is owned by one canonical sequence rather than split
  across incompatible assumptions.
- `prodbox host public-edge` renders a deterministic report when the edge stack is absent or
  partially torn down; missing cert-manager CRDs, absent Traefik services, or missing edge
  namespaces must classify the state instead of collapsing to an opaque DAG failure.
- Clean-cluster teardown and recreate leave no stale public-edge residue such as unsupported
  `/etc/hosts` overrides for `vscode.resolvefintech.com` or orphaned cluster-scoped edge objects
  that conflict with the canonical recreate path.
- Commands that load canonical settings auto-compile `prodbox-config.dhall` to the
  repository-root `prodbox-config.json` when the compiled artifact is missing or stale, so no
  supported CLI path depends on a manually prepared compiled config.
- The final handoff validation proves zero AWS residue through the aggregate supported test flow;
  it does not depend on a standalone `prodbox aws sweep-fixtures` command or host cron.

### Validation

1. `poetry run prodbox rke2 cleanup --yes`
2. `poetry run prodbox config show`
3. `poetry run prodbox config validate`
4. `poetry run prodbox test all`
5. `poetry run prodbox host public-edge`
6. `poetry run prodbox test integration public-dns`
7. `poetry run prodbox check-code`

### Current Validation State

- `poetry run prodbox rke2 cleanup --yes` passed on April 12, 2026.
- `rm -f prodbox-config.json` left the compiled config absent before the final validation run.
- `src/prodbox/settings.py` now auto-compiles the canonical repository Dhall config whenever the
  JSON artifact is missing or stale, and `tests/unit/test_settings.py` plus
  `tests/integration/test_cli_env.py` cover that behavior at both the settings-loader and CLI
  surfaces.
- `poetry run prodbox config show` and `poetry run prodbox config validate` both passed on
  April 12, 2026 and auto-regenerated `prodbox-config.json` from `prodbox-config.dhall`.
- `poetry run prodbox test all` passed on April 12, 2026 in `1h 33m 23s` from the cleaned RKE2
  cluster and missing compiled config; postflight restore rebuilt the supported runtime, redeployed
  the gateway and `vscode` stacks, and ended at `CLASSIFICATION=ready-for-external-proof`.
- The aggregate supported test flow now performs the final zero-AWS-residue proof through
  `src/prodbox/lib/aws_fixture_audit.py`; it does not invoke a standalone janitor command or
  depend on host cron supervision.
- `poetry run prodbox host public-edge` passed on April 12, 2026 and reported
  `CLASSIFICATION=ready-for-external-proof`.
- `poetry run prodbox test integration public-dns` passed on April 12, 2026 (2 tests).
- `crontab -l` returned no entries on April 12, 2026, and `/etc/hosts` contains no
  `vscode.resolvefintech.com` override.
- `poetry run prodbox check-code` passed on April 12, 2026 after the command and plan updates.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - final AWS-backed rerun posture.
- `documents/engineering/cli_command_surface.md` - canonical final validation path.
- `documents/engineering/distributed_gateway_architecture.md` - clean-cluster ownership boundary
  between RKE2 substrate restore and Pulumi-managed public-edge restore.
- `documents/engineering/helm_chart_platform_doctrine.md` - final `vscode` delivery and public-host
  posture.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained-storage posture at handoff.
- `documents/engineering/unit_testing_policy.md` - final authoritative test-command matrix.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep `README.md`, `00-overview.md`, `system-components.md`, `documents/engineering/README.md`,
  and the cleanup ledger aligned with the final handoff status.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
