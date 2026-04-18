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

## Current Baseline In Worktree

- The public `prodbox charts ...` runtime lives in `src/Prodbox/CLI/Charts.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Lib/Storage.hs`. All Python chart code
  has been removed from the repository.
- Retained roots remain the configured manual PV root (default `.data/`) and `.prodbox-state/`;
  chart secret resolution and gateway event-key handling are Haskell-owned.
- The custom `vscode-nginx` image build lives in `docker/nginx-oidc.Dockerfile` and uses the
  Harbor local-registry pipeline.

## Sprint 3.1: Haskell Chart Runtime and Deterministic Retained Storage ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

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

### Current Validation State

- `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and
  `src/Prodbox/Lib/Storage.hs` now own the default public Haskell runtime for
  `prodbox charts list|status|deploy|delete`, including deterministic retained storage,
  repo-local secret or event-key retention, Helm deploy or delete orchestration, and chart status
  rendering.
- `src/Prodbox/TestRunner.hs` supported-runtime bootstrap and postflight now invoke native Haskell
  `prodbox charts ...` surfaces instead of calling retained backend chart commands directly.
- `test/unit/Main.hs` now proves deterministic Haskell chart-plan and storage-binding behavior,
  and `test/integration/cli/Main.hs` now proves native built-frontend `prodbox charts
  list|status|deploy|delete` behavior against fake `helm` and `kubectl`.
- All Python chart code has been removed. The Haskell chart runtime is the sole owner of
  `prodbox charts list|status|deploy|delete`.
- The named validation commands in this sprint (`prodbox test integration charts-storage` and
  `prodbox test integration charts-platform`) now run executable native Haskell validation flows
  via `src/Prodbox/TestValidation.hs`.

### Remaining Work

None.

## Sprint 3.2: Haskell `vscode` Stack Delivery and Auth Path ✅

**Status**: Done
**Implementation**: `charts/`, `docker/nginx-oidc.Dockerfile`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

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

### Current Validation State

- The supported cluster-backed `vscode` delivery path remains Haskell-owned in the chart runtime
  and chart assets.
- `prodbox test integration charts-vscode` remains modeled as a pending native payload in
  `src/Prodbox/TestPlan.hs`; it now depends on reopened Sprint `1.2` harness closure and is not
  counted as part of today's passing local proof.

### Remaining Work

None.

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
