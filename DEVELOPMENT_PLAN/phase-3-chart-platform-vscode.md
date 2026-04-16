# Phase 3: Haskell Chart Platform and Cluster-Backed `vscode` Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell chart platform, deterministic retained storage model, and the
> supported cluster-backed `vscode` delivery path.

## Phase Summary

This phase ports the chart platform and retained-storage orchestration to Haskell while preserving
namespace-local stack composition, deterministic PV or PVC rebinding, and the supported cluster-
backed `vscode` delivery model.

## Sprint 3.1: Haskell Chart Runtime and Deterministic Retained Storage 📋

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `test/unit/charts/`, `test/integration/charts/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Move chart orchestration and retained-storage handling to Haskell without changing the supported
platform doctrine.

### Deliverables

- `prodbox charts list|status|deploy|delete` are implemented in Haskell.
- Deterministic retained storage under the configured manual PV root remains intact.
- `.prodbox-state/` remains the canonical retained non-PV chart-state root.
- Chart secret resolution and gateway event-key handling move to Haskell-owned modules.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-storage`
4. `prodbox test integration charts-platform`

### Remaining Work

- All deliverables remain open.

## Sprint 3.2: Haskell `vscode` Stack Delivery and Auth Path 📋

**Status**: Planned
**Implementation**: `charts/`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/integration/charts/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Preserve the supported cluster-backed `vscode` stack while moving its deployment orchestration to
Haskell.

### Deliverables

- The namespace-local `keycloak-postgres -> keycloak -> vscode` stack remains the supported app
  path.
- `vscode-nginx` remains the namespace-local auth proxy behind Traefik.
- The Haskell chart runtime owns deploy, status, and delete behavior for the `vscode` stack.
- Unsupported local-dev or non-cluster delivery paths remain absent from the supported
  architecture.

### Validation

1. `prodbox test integration charts-platform`
2. `prodbox test integration charts-vscode`

### Remaining Work

- All deliverables remain open.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell `prodbox charts` surface.
- `documents/engineering/helm_chart_platform_doctrine.md` - Haskell chart runtime and supported
  stack topology.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding doctrine.
- `documents/engineering/local_registry_pipeline.md` - container-build implications for the Haskell
  runtime where relevant.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the cluster-backed `vscode` path.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
