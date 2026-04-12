# File: DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md
# Phase 6: Final Clean-Room Rerun and Zero-Legacy Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the final repository handoff criteria: a full clean-room rerun through
> canonical entrypoints only and an empty remaining legacy inventory.

## Phase Summary

This phase reruns the authoritative validation set from the supported operator flow after the
blocked AWS and public-host proofs close. The repository hands off only when no sprint remains
blocked or active and the cleanup ledger is empty. The original Sprint 6.1 closeout established
the intended handoff contract, but Sprint 6.2 reopens the phase because the repository still
needs one final clean-room rerun that starts from both a cleaned RKE2 cluster and a repository
state without a precompiled `prodbox-config.json`, then re-proves zero AWS residue after the
aggregate suite.

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
- `poetry run prodbox test unit` passed on April 12, 2026 (972 tests).
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

## Sprint 6.2: Clean-Cluster Aggregate Bootstrap and Zero-AWS-Residue Closure 🔄

**Status**: Active
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `tests/unit/test_settings.py`, `tests/integration/test_cli_env.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/aws_helpers.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the aggregate validation path self-healing from a completely cleaned RKE2 cluster and a
repository state without a precompiled `prodbox-config.json`, then prove that the same rerun
leaves no fixture-owned AWS resources behind.

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
- The final handoff validation includes an immediate post-aggregate zero-AWS-residue proof through
  the canonical janitor surface.

### Validation

1. `poetry run prodbox rke2 cleanup --yes`
2. `poetry run prodbox config show`
3. `poetry run prodbox config validate`
4. `poetry run prodbox test all`
5. `poetry run prodbox host public-edge`
6. `poetry run prodbox test integration public-dns`
7. `poetry run prodbox aws sweep-fixtures`
8. `poetry run prodbox check-code`

### Current Validation State

- `poetry run prodbox rke2 cleanup --yes` followed by `poetry run prodbox test all` completed
  successfully on April 12, 2026 when the repository-root `prodbox-config.json` artifact already
  existed; the aggregate postflight restored the supported runtime and the final
  `poetry run prodbox aws sweep-fixtures` run reported no fixture-owned Route 53, S3, VPC, EKS,
  or IAM resources remaining.
- A second `poetry run prodbox test all` invocation at 17:31 on April 12, 2026 failed in
  `Phase 1.6/2: restoring supported runtime` with `[Errno 2] No such file or directory:
  '/home/matthewnowak/prodbox/prodbox-config.json'` after `prodbox-config.dhall` changed and the
  compiled JSON artifact was absent.
- The missing-file failure showed that supported commands still assumed a precompiled
  repository-root JSON artifact even though the Dhall source remained present.
- `src/prodbox/settings.py` now auto-compiles the canonical repository Dhall config whenever the
  JSON artifact is missing or stale, and `tests/unit/test_settings.py` plus
  `tests/integration/test_cli_env.py` now cover that behavior at both the settings-loader and CLI
  surfaces.
- `poetry run prodbox config show` and `poetry run prodbox config validate` both passed on
  April 12, 2026 after the repository-root `prodbox-config.json` artifact was removed; each
  command regenerated the JSON artifact automatically from `prodbox-config.dhall`.
- `poetry run prodbox pulumi refresh` also passed on April 12, 2026 after the repository-root
  `prodbox-config.json` artifact was removed, proving that the Phase 1.6 restore-class command
  surface no longer depends on a manually prepared compiled config.
- `poetry run prodbox check-code` passed on April 12, 2026 after the command and plan updates.

### Remaining Work

- Re-run the full clean-room handoff proof from a state where the repository-root
  `prodbox-config.json` does not exist before command execution begins.
- Keep the final handoff contract tied to both clean states simultaneously: a cleaned RKE2
  cluster and a repo that requires on-demand Dhall compilation.

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
