# File: DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md
# Phase 6: Final Clean-Room Rerun and Zero-Legacy Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the final repository handoff criteria: a full clean-room rerun through
> canonical entrypoints only and an empty remaining legacy inventory.

## Phase Summary

This phase reruns the authoritative validation set from the supported operator flow after the
public-host and AWS cleanup proofs close. Under the reopened doctrine, the previous final handoff
proof is no longer sufficient because the supported clean-room path must now start from a full
local cluster delete that preserves the configured manual PV root plus the repo-local
`.prodbox-state/` retained chart-state root, plus a missing compiled config artifact, then rebuild
the local cluster and MinIO backend, execute both intended AWS-backed deployment patterns under
`prodbox` (the EKS-backed path and the remote three-node HA RKE2-over-SSH path), and finally
destroy the Pulumi-managed AWS test resources before handoff. Both AWS-backed validation branches
and the zero-legacy cleanup now exist in the worktree and are closed on the supported destructive
baseline. The repository now hands off with no active or blocked sprint and an empty cleanup
ledger.

## Sprint 6.1: Final Clean-Room Validation Rerun and Zero-Legacy Handoff ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/infra/cert_manager.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/metallb.py`, `tests/unit/test_infra_program.py`, `tests/unit/test_test_cmd.py`, `documents/engineering/cli_command_surface.md`, `documents/engineering/unit_testing_policy.md`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Establish the first clean-room aggregate rerun through canonical entrypoints and record the
empty-ledger baseline that later handoff sprints extend.

### Deliverables

- The first clean-room aggregate validation set reruns through canonical entrypoints only.
- Docs under `documents/` remain doctrine-only and defer status tracking to this plan suite.
- The April 12, 2026 baseline closes with an empty legacy inventory.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration all`
4. `poetry run prodbox tla-check`
5. `poetry run prodbox test integration public-dns`

### Current Validation State

- This sprint established the first full clean-room aggregate rerun through named `prodbox`
  commands only on April 12, 2026.
- `poetry run prodbox check-code` passed on April 12, 2026.
- `poetry run prodbox test unit` passed on April 12, 2026 (`982 passed`).
- `poetry run prodbox test integration all`, `poetry run prodbox tla-check`, and
  `poetry run prodbox test integration public-dns` all passed on April 12, 2026.
- `poetry run prodbox test all` completed cleanly on April 12, 2026 after postflight runtime
  restore returned `prodbox host public-edge` to `CLASSIFICATION=ready-for-external-proof`.
- Aggregate suites now run `test_charts_platform.py` before `test_charts_storage.py`, restore the
  supported runtime with `prodbox pulumi refresh`, `prodbox pulumi up --yes`,
  `prodbox charts deploy gateway`, and `prodbox charts deploy vscode` after the destructive pytest
  tail, and then re-check `prodbox host public-edge` before exit.
- Later sprints in this phase extend the same clean-room proof from full `prodbox rke2 delete --yes`,
  a missing compiled config artifact, the Pulumi-managed remote HA validation path, and eventually
  the planned EKS-backed path.

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

- Starting from the prior cleaned-cluster baseline and a repository state without a
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
- Aggregate supported-runtime repair idempotently selects or creates the canonical Pulumi `home`
  stack before raw Pulumi AWS/provider repair runs, so `poetry run prodbox test all` does not
  depend on a manual `pulumi stack select`.
- The final handoff validation proves zero AWS residue through the aggregate supported test flow;
  it does not depend on any standalone janitor command or host cron.

### Validation

1. Prior cleaned-cluster baseline on the supported host
2. `poetry run prodbox config show`
3. `poetry run prodbox config validate`
4. `poetry run prodbox test all`
5. `poetry run prodbox host public-edge`
6. `poetry run prodbox test integration public-dns`
7. `poetry run prodbox check-code`

### Current Validation State

- `rm -f prodbox-config.json` left the compiled config absent before the April 12, 2026 closure
  rerun.
- `src/prodbox/settings.py` auto-compiles the canonical repository Dhall config whenever the JSON
  artifact is missing or stale, and `tests/unit/test_settings.py` plus
  `tests/integration/test_cli_env.py` cover that behavior at both the settings-loader and CLI
  surfaces.
- `poetry run prodbox config show` and `poetry run prodbox config validate` both passed on
  April 12, 2026 and auto-regenerated `prodbox-config.json` from `prodbox-config.dhall`.
- `poetry run prodbox test all` passed on April 12, 2026 in `1h 33m 23s` from the cleaned RKE2
  cluster and missing compiled config; postflight restore rebuilt the supported runtime, redeployed
  the gateway and `vscode` stacks, and ended at `CLASSIFICATION=ready-for-external-proof`.
- The aggregate supported test flow performs the zero-AWS-residue proof through the
  supported-runtime postflight, including `prodbox pulumi test-destroy --yes`; it does not invoke
  a standalone janitor command or depend on host cron supervision.
- `poetry run prodbox host public-edge` passed on April 12, 2026 and reported
  `CLASSIFICATION=ready-for-external-proof`.
- `poetry run prodbox test integration public-dns` passed on April 12, 2026 (2 tests).
- The supported host no longer depends on cleanup residue such as a `crontab` janitor entry or an
  `/etc/hosts` override for `vscode.resolvefintech.com`.
- Later sprints in this phase extend this clean-cluster baseline to the full delete/install path,
  the remote-HA rerun path, and eventually the planned EKS-backed rerun path.

### Remaining Work

None.

## Sprint 6.3: Final Handoff Proof from Full Cluster Delete and Missing Compiled Config ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/rke2.py`, `tests/integration/test_prodbox_lifecycle.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Re-prove the clean-room baseline from a full cluster delete and a missing compiled config artifact
under the new host-owned lifecycle doctrine.

### Deliverables

- The authoritative rerun starts from `poetry run prodbox rke2 delete --yes` and a missing
  repository-root `prodbox-config.json`.
- Cluster delete preserves the configured manual PV host root plus the repo-local `.prodbox-state/`
  retained chart-state root and removes every other managed cluster remnant.
- `poetry run prodbox rke2 install` restores the canonical substrate on `Ubuntu 24.04 LTS` without
  manual operator repair.
- The rerun finishes at `CLASSIFICATION=ready-for-external-proof` and re-proves zero AWS residue
  through the aggregate supported test flow.

### Validation

1. `poetry run prodbox rke2 delete --yes`
2. `rm -f prodbox-config.json`
3. `poetry run prodbox rke2 install`
4. `poetry run prodbox config show`
5. `poetry run prodbox config validate`
6. `poetry run prodbox test all`
7. `poetry run prodbox host public-edge`
8. `poetry run prodbox test integration public-dns`
9. `poetry run prodbox check-code`

### Closure Validation (2026-04-13)

- `poetry run prodbox rke2 delete --yes` passed on April 13, 2026 and reported preserved roots
  `/home/matthewnowak/prodbox/.data` and `/home/matthewnowak/prodbox/.prodbox-state`.
- `rm -f prodbox-config.json` removed the compiled artifact before the closure rerun.
- `poetry run prodbox rke2 install` passed on April 13, 2026 in `6m 40s` on `Ubuntu 24.04.4 LTS`;
  `systemctl is-enabled rke2-server` returned `enabled`.
- `poetry run prodbox config show` and `poetry run prodbox config validate` both passed on
  April 13, 2026 and auto-regenerated `prodbox-config.json`; `config show` reported
  `storage.manual_pv_host_root=/home/matthewnowak/prodbox/.data`.
- `poetry run prodbox test all` passed on April 13, 2026 in `1h 27m 34s` and restored the runtime
  to `CLASSIFICATION=ready-for-external-proof`.
- `poetry run prodbox host public-edge` passed on April 13, 2026 and reported
  `CLASSIFICATION=ready-for-external-proof`, `CERTIFICATE_READY=true`, and
  `PRIVATE_EDGE_READY=true`.
- `poetry run prodbox test integration public-dns` passed on April 13, 2026 (2 tests).
- `poetry run prodbox check-code` passed on April 13, 2026 after the closure updates.
- At the April 13, 2026 closure point the legacy ledger was empty; Sprint 6.4 later
  revalidated the same handoff with the Pulumi-owned AWS test stack and the HA-over-SSH proof on
  April 14, 2026.

### Remaining Work

None.

## Sprint 6.4: Final Clean-Room Proof for Local-Backend and Remote-HA Validation ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/rke2.py`, `src/prodbox/lib/aws_test_stack.py`, `src/prodbox/infra/aws_test_stack_program.py`, `tests/integration/test_ha_rke2_aws.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Re-prove the implemented HA RKE2 branch of the clean-room handoff from full local cluster delete
and missing compiled config through local MinIO backend restore, remote HA RKE2 deployment over
SSH, and final Pulumi-owned AWS teardown.

### Deliverables

- The authoritative rerun starts from `poetry run prodbox rke2 delete --yes` and a missing
  repository-root `prodbox-config.json`.
- The host machine reinstalls the local RKE2 cluster first, restores the MinIO backend, and makes
  the dedicated bucket `prodbox-test-pulumi-backends` available before any remote AWS test stack
  exists.
- `prodbox pulumi test-resources` provisions or inspects the remote three-node AWS test stack, and
  the named `ha-rke2-aws` suite proves HA RKE2 deployment over SSH on three separate-AZ
  `Ubuntu 24.04 LTS` EC2 instances.
- `prodbox pulumi test-destroy --yes` destroys the remote AWS test stack, and the same destroy
  path is automatically invoked by `prodbox rke2 delete --yes` before local backend teardown.
- The rerun finishes at `CLASSIFICATION=ready-for-external-proof` and leaves no Pulumi-managed AWS
  resources or backend-bucket residue behind.

### Validation

1. `poetry run prodbox rke2 delete --yes`
2. `rm -f prodbox-config.json`
3. `poetry run prodbox rke2 install`
4. `poetry run prodbox config show`
5. `poetry run prodbox config validate`
6. `poetry run prodbox pulumi test-resources`
7. `poetry run prodbox test integration ha-rke2-aws`
8. `poetry run prodbox pulumi test-destroy --yes`
9. `poetry run prodbox test all`
10. `poetry run prodbox host public-edge`
11. `poetry run prodbox test integration public-dns`
12. `poetry run prodbox check-code`

### Current Validation State

- `poetry run prodbox rke2 delete --yes`, `rm -f prodbox-config.json`, `poetry run prodbox rke2 install`, `poetry run prodbox config show`, and `poetry run prodbox config validate` passed on April 13, 2026 from the missing compiled-config baseline required by the clean-room handoff.
- `poetry run prodbox pulumi test-resources` passed on April 14, 2026 and created the canonical three-node AWS test stack.
- The HA-over-SSH proof executed by `poetry run prodbox test integration ha-rke2-aws` passed
  again inside the April 15, 2026 destructive rerun as
  `tests/integration/test_ha_rke2_aws.py::test_ha_rke2_bootstrap_succeeds_on_three_pulumi_managed_nodes`.
- `poetry run prodbox host public-edge` passed on April 13, 2026 and `poetry run prodbox test integration public-dns` passed on April 13, 2026 (2 tests); the April 14 aggregate rerun re-proved the same public-edge state during its restore tail.
- `poetry run prodbox pulumi test-destroy --yes` passed on April 14, 2026 and verified no AWS residue plus an empty backend bucket `prodbox-test-pulumi-backends`.
- A final `poetry run prodbox rke2 delete --yes` passed on April 14, 2026, auto-ran the shared Pulumi destroy path first, preserved only `.data/` and `.prodbox-state/`, left `rke2-server` inactive, and left `kubectl` unable to reach a cluster.
- The April 15, 2026 destructive rerun fixed and re-proved the last clean-room gaps on the supported path: blank operational `aws.*` credentials are now restored from raw-config `aws_admin.*` before settings load, the supported-runtime preflight now idempotently selects or creates the canonical `home` stack and advances stale Pulumi AWS provider state before `pulumi refresh`, and Harbor image publication re-authenticates after a fully pruned Docker baseline.
- `poetry run prodbox rke2 delete --yes`, `docker system prune -af --volumes`, `sudo rm -rf .data`,
  and `poetry run prodbox test all` passed on April 15, 2026 from a local file-backed Pulumi
  backend with no active stack selection; the aggregate rerun finished in `1h 42m 48s`, re-proved
  the Pulumi lifecycle, HA-over-SSH, lifecycle, and IAM suites from the wiped baseline, restored
  the supported runtime to `CLASSIFICATION=ready-for-external-proof`, and auto-destroyed both
  `aws-eks-test` and `aws-test` with an empty backend bucket.
- These validations closed the HA RKE2 branch first; Sprint 6.5 later closed the companion
  EKS-backed branch and the full dual-path handoff on April 15, 2026.

### Remaining Work

None.

## Sprint 6.5: Final Clean-Room Proof for Dual AWS Deployment Patterns ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/infra/aws_eks_test_stack_program.py`, `src/prodbox/lib/aws_eks_test_stack.py`, `tests/integration/test_aws_eks.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the final clean-room handoff only after the supported rerun proves both intended AWS-backed
deployment patterns, EKS-backed and HA RKE2-over-SSH, from the same canonical baseline and after
the latest destructive rerun re-proves the now-empty legacy ledger.

### Deliverables

- The authoritative rerun starts from `poetry run prodbox rke2 delete --yes` and a missing
  repository-root `prodbox-config.json`.
- The host machine reinstalls the local RKE2 cluster first, restores the MinIO backend, and makes
  the dedicated bucket `prodbox-test-pulumi-backends` available before either AWS-backed
  validation pattern runs.
- One supported both-path rerun exists through named `prodbox` commands only: the EKS-backed
  create/validate/destroy path and the HA RKE2 create/validate/destroy path both close from the
  same cleanup doctrine.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is now empty in `Pending
  Removal`; the surviving `config init` migration shim, `/var/lib/prodbox/storage` cleanup helper,
  and stale `.env` AWS credential hint are already gone.
- The rerun finishes at `CLASSIFICATION=ready-for-external-proof` and leaves no Pulumi-managed AWS
  resources or backend-bucket residue behind regardless of which AWS-backed cluster pattern ran.

### Validation

1. `poetry run prodbox rke2 delete --yes`
2. `rm -f prodbox-config.json`
3. `poetry run prodbox rke2 install`
4. `poetry run prodbox config show`
5. `poetry run prodbox config validate`
6. `poetry run prodbox pulumi eks-resources`
7. `poetry run prodbox test integration aws-eks`
8. `poetry run prodbox pulumi eks-destroy --yes`
9. `poetry run prodbox pulumi test-resources`
10. `poetry run prodbox test integration ha-rke2-aws`
11. `poetry run prodbox pulumi test-destroy --yes`
12. `poetry run prodbox test all`
13. `poetry run prodbox host public-edge`
14. `poetry run prodbox test integration public-dns`
15. `poetry run prodbox check-code`

### Current Validation State

- Sprint 6.4 closes the HA RKE2 clean-room branch from the supported baseline through final
  Pulumi destroy, and Sprint 1.5 closes the companion EKS-backed branch through
  `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`, and
  `poetry run prodbox test integration aws-eks`.
- `prodbox rke2 delete --yes` now destroys both Pulumi-managed AWS stacks before local backend
  teardown, so the clean-room delete boundary matches the final both-path handoff doctrine.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) now has no pending-removal
  entries.
- `poetry run prodbox check-code` passed on April 15, 2026 after the final
  status-documentation refresh.
- `poetry run prodbox test unit` passed on April 15, 2026 (`1078 passed`) after the EKS and
  zero-legacy closure work.
- `poetry run prodbox pulumi eks-resources`, `poetry run prodbox test integration aws-eks`, and
  `poetry run prodbox pulumi eks-destroy --yes` passed on April 15, 2026; the named EKS suite
  `tests/integration/test_aws_eks.py` passed (`1 passed` in `22m 03s`).
- `poetry run prodbox rke2 delete --yes` passed on April 15, 2026 before the destructive rerun,
  destroyed `aws-eks-test` and `aws-test`, preserved `.data` plus `.prodbox-state`, and left the
  shared backend bucket empty before local-cluster teardown.
- `docker system prune -af --volumes` and `sudo rm -rf .data` both passed on April 15, 2026,
  proving the final rerun from a pruned Docker baseline and a removed manual PV root.
- `poetry run prodbox test all` passed on April 15, 2026 in `1h 42m 48s` from a local file-backed
  Pulumi backend with no active stack selection; the aggregate rerun selected or created the
  canonical `home` stack during supported-runtime repair and included
  `tests/integration/test_public_dns_delegation.py`,
  `tests/integration/test_aws_eks.py`, `tests/integration/test_pulumi_real.py`,
  `tests/integration/test_ha_rke2_aws.py`, `tests/integration/test_charts_storage.py`,
  `tests/integration/test_prodbox_lifecycle.py`, and
  `tests/integration/test_aws_iam_lifecycle.py`, restored the supported runtime to
  `CLASSIFICATION=ready-for-external-proof`, and auto-destroyed both `aws-eks-test` and
  `aws-test` with an empty backend bucket.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - final AWS-backed rerun posture,
  the local-cluster-first MinIO backend, and Pulumi-exclusive teardown across both intended
  AWS-backed deployment patterns.
- `documents/engineering/aws_test_environment.md` - local MinIO backend plus the three-node,
  separate-AZ `Ubuntu 24.04 LTS` HA RKE2 test environment plus the implemented companion EKS path.
- `documents/engineering/cli_command_surface.md` - canonical final validation path including
  `rke2 install|delete`, the EKS-backed validation surface, `pulumi test-resources`, and
  `pulumi test-destroy --yes`.
- `documents/engineering/prerequisite_doctrine.md` - Ubuntu 24.04 support gate, the
  local-cluster-first backend prerequisite, and the final clean-room prerequisite path.
- `documents/engineering/storage_lifecycle_doctrine.md` - preserved manual PV root plus
  delete/reinstall rebinding posture and the pre-delete Pulumi destroy ordering at handoff.
- `documents/engineering/unit_testing_policy.md` - final authoritative test-command matrix,
  `ha-rke2-aws` ownership, `aws-eks` ownership, and delete/install rerun proof.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep `README.md`, `00-overview.md`, `system-components.md`, and the cleanup ledger aligned with
  the closed dual-path final-handoff status and the empty pending-removal ledger.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
