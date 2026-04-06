# File: DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md
# Phase 3: Chart Platform and Cluster-Backed `vscode` Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the canonical chart platform, deterministic retained storage model, and the
> supported cluster-backed `vscode` delivery path.

## Phase Summary

This phase defines the chart-lifecycle platform, deterministic retained storage rooted at `.data/`,
and the namespace-local `keycloak-postgres -> keycloak -> vscode` stack with nginx OIDC plus local
Keycloak users as the supported auth model.

## Sprint 3.1: Chart Platform and Deterministic Retained Storage ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/charts.py`, `src/prodbox/lib/chart_platform.py`, `tests/integration/test_charts_storage.py`, `tests/integration/test_charts_platform.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Deliver one canonical chart-lifecycle platform with deterministic retained storage.

### Deliverables

- `prodbox charts list|status|deploy|delete` is the canonical chart surface.
- CLI-owned chart storage lives under `.data/<namespace>/<statefulset>/<ordinal>`.
- End-to-end chart integration covers retained storage and stack deploy/delete behavior.
- Delete and redeploy preserve deterministic PV/PVC rebinding on the same retained host paths.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration charts-storage`
4. `poetry run prodbox test integration charts-platform`

### Remaining Work

None.

## Sprint 3.2: `vscode` Stack and Canonical Cluster Auth Path ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/charts.py`, `tests/integration/test_charts_platform.py`, `tests/integration/test_charts_vscode.py`, `documents/engineering/helm_chart_platform_doctrine.md`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Deliver the supported cluster-backed `vscode` stack and one canonical in-cluster auth path.

### Deliverables

- The namespace-local `keycloak-postgres -> keycloak -> vscode` stack exists.
- nginx OIDC plus local Keycloak username/password is the supported auth model.
- `KEYCLOAK_NGINX_CLIENT_SECRET` is the intended shared auth-secret setting.
- Unsupported non-cluster local-dev delivery content is removed from the repository.
- Live public-host closure is deferred explicitly to Phase 5.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration charts-platform`

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical `prodbox charts` command matrix.
- `documents/engineering/helm_chart_platform_doctrine.md` - namespace-local stack and auth-path
  doctrine.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding contract.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep `README.md` and the engineering index aligned with the cluster-backed `vscode` path.
