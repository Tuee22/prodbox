# File: DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md
# Phase 4: Lifecycle Hardening and Canonical-Path Cleanup

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

> **Purpose**: Capture the lifecycle hardening work that removes cleanup-settling retries and the
> canonical-path cleanup work that leaves one supported surface per major capability.

## Phase Summary

This phase hardens `rke2 cleanup` until lifecycle validation passes without settling retries, then
removes duplicate or compatibility-only runtime, CLI, validation, and tooling paths. All cleanup
history remains centralized in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 4.1: `rke2 cleanup` Hardening and Lifecycle Regression Closure ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/rke2.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_prodbox_lifecycle.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Make `rke2 cleanup` stable enough that the lifecycle suite does not need retry-based settling.

### Deliverables

- Namespace-first cleanup replaces the old multi-pass cleanup implementation.
- Retained kinds (`PersistentVolume`, `StorageClass`, `PersistentVolumeClaim`) are preserved by
  doctrine.
- The lifecycle suite proves first-attempt cleanup success and retained-storage rebinding without a
  cleanup-settling shim.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration lifecycle`

### Remaining Work

None.

## Sprint 4.2: Canonical-Path Cleanup and Legacy Removal ⏸️

**Status**: Blocked
**Implementation**: `src/prodbox/cli/gateway.py`, `src/prodbox/settings.py`, `src/prodbox/cli/summary.py`, `src/prodbox/lib/lint/`
**Blocked by**: external AWS Route 53 permissions needed to rerun `dns-aws`, `pulumi`, and `public-dns`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Collapse each major surface to one canonical runtime path, one canonical CLI path, and one
canonical automated validation path.

### Deliverables

- Compatibility-only or duplicate operator paths are removed instead of preserved.
- Doctrine docs remain architectural and current; transitional removal timing lives only in this
  plan suite.
- Workflow and tooling residue that conflicts with the supported operator doctrine is removed.
- The remaining legacy inventory contains only genuinely unresolved items.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. `poetry run prodbox test integration gateway-daemon`
5. `poetry run prodbox test integration gateway-pods`
6. `poetry run prodbox test integration charts-platform`
7. `poetry run prodbox test integration dns-aws`
8. `poetry run prodbox test integration pulumi`

### Current Validation State

- Repository-wide status tracking has been centralized in this plan suite.
- The `rke2_killall_exists` prerequisite has been removed.
- The legacy Poetry `daemon` entrypoint and direct daemon wrapper path are gone.
- The CLI/DDNS Route 53 update and timer path are gone.
- The interpreter and summary layer now use one canonical structured DAG outcome model.
- Pulumi subprocess handling now injects `PRODBOX_ALLOW_NON_ENTRYPOINT=1`.
- `Settings()` reads `.env` only from the fixed repository root.
- The certificate issuance path is canonicalized to `letsencrypt-http01`.
- Hook-oriented `pre-commit` dependency and config residue are gone.

### Remaining Work

- Rerun `poetry run prodbox test integration dns-aws` in an AWS environment with
  `route53:CreateHostedZone`.
- Rerun `poetry run prodbox pulumi up --yes` and `poetry run prodbox test integration pulumi` in
  an AWS environment with `route53:GetHostedZone`.
- Rerun `poetry run prodbox test integration public-dns` in an AWS environment with
  `route53:GetHostedZone` access to `ROUTE53_ZONE_ID`.
- Close the sprint only after the blocked AWS-backed proof paths pass from the canonical CLI
  surface.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - blocked AWS rerun rules and
  canonical auth ownership.
- `documents/engineering/cli_command_surface.md` - canonical command and validation paths.
- `documents/engineering/dependency_management.md` - supported local tooling doctrine.
- `documents/engineering/distributed_gateway_architecture.md` - gateway startup and DNS ownership.
- `documents/engineering/helm_chart_platform_doctrine.md` - supported chart and `vscode` paths.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite registry cleanup.
- `documents/engineering/unit_testing_policy.md` - authoritative named validation paths.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep cleanup and compatibility ownership pointed at
  `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.
