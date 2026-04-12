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
the intended handoff contract, but Sprint 6.2 reopens the phase because the current clean-cluster
rerun from `poetry run prodbox rke2 cleanup --yes` does not yet recreate the supported public-edge
stack deterministically or re-prove zero AWS residue after the aggregate suite.

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
**Implementation**: `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/rke2.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/test_prodbox_lifecycle.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/test_public_dns_delegation.py`, `tests/integration/aws_helpers.py`, `tests/integration/conftest.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the aggregate validation path self-healing from a completely cleaned RKE2 cluster and prove
that the same rerun leaves no fixture-owned AWS resources behind.

### Deliverables

- Starting from `poetry run prodbox rke2 cleanup --yes`, the supported aggregate rerun path
  restores MetalLB, Traefik, cert-manager, the issuer/bootstrap layer, the in-cluster gateway,
  and the `vscode` stack without manual operator repair.
- The aggregate suite no longer calls the public-edge readiness gate before the Pulumi-managed
  edge stack exists, and the restore path is owned by one canonical sequence rather than split
  across incompatible assumptions.
- `prodbox host public-edge` renders a deterministic report when the edge stack is absent or
  partially torn down; missing cert-manager CRDs, absent Traefik services, or missing edge
  namespaces must classify the state instead of collapsing to an opaque DAG failure.
- Clean-cluster teardown and recreate leave no stale public-edge residue such as unsupported
  `/etc/hosts` overrides for `vscode.resolvefintech.com` or orphaned cluster-scoped edge objects
  that conflict with the canonical recreate path.
- The final handoff validation includes an immediate post-aggregate zero-AWS-residue proof through
  the canonical janitor surface.

### Validation

1. `poetry run prodbox rke2 cleanup --yes`
2. `poetry run prodbox test all`
3. `poetry run prodbox host public-edge`
4. `poetry run prodbox test integration public-dns`
5. `poetry run prodbox aws sweep-fixtures`
6. `poetry run prodbox check-code`

### Current Validation State

- `poetry run prodbox test all` failed on April 12, 2026 after the runbook phase before pytest
  suite execution began; the surfaced failure was `public-edge diagnostic failed`.
- `poetry run prodbox host public-edge` failed on April 12, 2026 because
  `kubectl get certificate vscode-tls -n vscode -o json --ignore-not-found=true` returned
  `error: the server doesn't have a resource type "certificate"`.
- `kubectl get ns` on April 12, 2026 showed `metallb-system`, `traefik-system`, and
  `cert-manager` absent, while `helm list -A` showed no `metallb`, `traefik`, or
  `cert-manager` releases.
- `kubectl get ingressclass traefik -o yaml` and `kubectl get crd` still show Traefik
  cluster-scoped residue, so the current clean-cluster recreate path is not deterministic.
- Public resolvers return `142.115.123.42` for `vscode.resolvefintech.com`, but `/etc/hosts` on
  `bathurst` still overrides the hostname to `192.168.2.240`.
- The last known `poetry run prodbox aws sweep-fixtures` audit on April 12, 2026 found no
  fixture-owned Route 53, S3, VPC, EKS, or IAM resources, but that proof has not yet been
  rerun immediately after a successful clean-cluster aggregate suite.

### Remaining Work

- Define one canonical aggregate bootstrap order from `poetry run prodbox rke2 cleanup --yes`
  through public-edge readiness, and remove the current split between `rke2 ensure` and the
  Phase 1.5 public-edge gate.
- Make `prodbox host public-edge` classify missing-edge states without failing on absent
  cert-manager CRDs or other expected clean-cluster conditions.
- Remove or fail fast on unsupported `/etc/hosts` public-host overrides during authoritative
  external proof.
- Prove that cleanup plus recreate does not leave stale cluster-scoped public-edge residue that
  interferes with the canonical restore path.
- Add a required post-aggregate zero-AWS-residue proof to the final handoff contract.

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
