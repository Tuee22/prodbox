# Phase 3: Haskell Chart Platform and Cluster-Backed `vscode` Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell chart platform, deterministic retained storage model, and the
> supported cluster-backed `vscode` delivery path.

## Phase Summary

This phase ports the chart platform and retained-storage orchestration to Haskell while preserving
deterministic PV/PVC rebinding and the supported cluster-backed `vscode` delivery model. It owns
retained storage, Harbor-backed image sourcing for the supported chart stack, the
`vscode-nginx` image exception under the repository Docker doctrine, and the PostgreSQL doctrine
for every Helm-managed application stack.

As of April 24, 2026, this phase remains closed. The supported chart platform is Haskell-owned, the
`vscode` stack stays on Harbor-backed images after Harbor bootstrap, and every Helm-managed
PostgreSQL dependency now lands on the external Patroni-based doctrine: exactly three replicas,
synchronous replication, and no embedded chart-local PostgreSQL subchart.

## Current Baseline In Worktree

- The public `prodbox charts ...` runtime lives in `src/Prodbox/CLI/Charts.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Lib/Storage.hs`.
- Retained roots remain the configured manual PV root (default `.data/`) and `.prodbox-state/`;
  chart secret resolution and gateway event-key handling are Haskell-owned.
- `docker/nginx-oidc.Dockerfile` remains the permitted `nginx:1.25-alpine` exception and is
  published to Harbor before supported deployment.
- The chart dependency graph is now `keycloak-postgres -> keycloak -> vscode` for the supported
  app stack.
- `keycloak-postgres` renders a Patroni cluster resource in the root chart namespace, depends on
  the lifecycle-owned `postgres-operator` platform, and stores data under deterministic manual-PV
  bindings.
- `keycloak` now consumes the operator-generated Patroni credentials secret and the namespace-local
  primary service endpoint instead of a shared `pgpool` service.
- `src/Prodbox/TestPlan.hs` maps the chart validation names to executable native validations in
  `src/Prodbox/TestValidation.hs`.

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

- `test/unit/Main.hs` proves deterministic Haskell chart-plan and storage-binding behavior.
- `test/integration/cli/Main.hs` proves native built-frontend `prodbox charts
  list|status|deploy|delete` behavior against fake `helm` and `kubectl`.
- The last completed cluster-backed chart-platform closure reruns remain the April 23, 2026 runs:
  `./.build/prodbox check-code`, `./.build/prodbox test unit`,
  `./.build/prodbox test integration charts-storage`, and
  `./.build/prodbox test integration charts-platform`, then those same chart-platform proofs inside
  `./.build/prodbox test integration all` and `./.build/prodbox test all`.

### Remaining Work

None.

## Sprint 3.2: Haskell `vscode` Stack Delivery and Auth Path ✅

**Status**: Done
**Implementation**: `charts/`, `docker/nginx-oidc.Dockerfile`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Preserve the supported cluster-backed `vscode` stack while moving its deployment orchestration and
image sourcing to the canonical Harbor-first doctrine.

### Deliverables

- The supported app path is `external PostgreSQL -> keycloak -> vscode`.
- `vscode-nginx` remains the namespace-local auth proxy behind Traefik.
- `vscode-nginx` is loaded into Harbor before deployment and referenced from Harbor on the
  supported path.
- The Haskell chart runtime owns deploy, status, and delete behavior for the `vscode` stack.
- Both `amd64` and `arm64` variants of the auth-proxy image are published or loaded irrespective
  of the architecture of the machine running `prodbox`.

### Validation

1. `prodbox test integration charts-platform`
2. `prodbox test integration charts-vscode`
3. Image-source proof: the supported chart or rendered manifests reference Harbor for
   `vscode-nginx`
4. Harbor proof: both `amd64` and `arm64` variants of the auth-proxy image are available

### Current Validation State

- `src/Prodbox/TestPlan.hs` keeps `prodbox test integration charts-vscode` on the supported
  runtime bootstrap path rather than bypassing the cluster runbook.
- `src/Prodbox/TestRunner.hs` waits for `prodbox host public-edge` to report
  `CLASSIFICATION=ready-for-external-proof` before the external `charts-vscode` curl proof
  continues.
- The last completed cluster-backed `vscode` closure reruns remain the April 23, 2026 runs:
  `./.build/prodbox test integration charts-vscode` on the Harbor-backed
  `keycloak-postgres -> keycloak -> vscode` path, plus the same public-edge redirect proof inside
  `./.build/prodbox test integration all` and `./.build/prodbox test all`.

### Remaining Work

None.

## Sprint 3.3: External Patroni PostgreSQL Doctrine for Helm Workloads ✅

**Status**: Done
**Implementation**: `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/ContainerImage.hs`, `charts/`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Replace the former shared PostgreSQL application-database doctrine with external Patroni-based HA
PostgreSQL for every Helm-managed PostgreSQL dependency.

### Deliverables

- Every supported Helm-managed PostgreSQL dependency consumes an external Patroni-based HA
  deployment rather than an embedded chart-local PostgreSQL subchart.
- Every supported Patroni deployment runs exactly three PostgreSQL replicas with synchronous
  replication enabled.
- Patroni-related images are Harbor-backed on the supported path after Harbor bootstrap.
- `keycloak`, `vscode`, and any later PostgreSQL-backed chart stack declare external database
  connectivity instead of rendering or depending on embedded PostgreSQL.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-vscode`
5. Manifest proof: supported chart renders disable embedded PostgreSQL and target external
   Patroni service endpoints
6. Image-source proof: Patroni-related chart workloads reference Harbor-backed images on the
   supported path

### Current Validation State

- `src/Prodbox/PostgresPlatform.hs` now defines the Patroni operator, cluster, service, and secret
  naming contract.
- `src/Prodbox/Lib/ChartPlatform.hs` now renders `keycloak-postgres`, injects the operator
  credentials secret into `keycloak`, and validates the cluster-wide Patroni platform before chart
  deploy.
- `src/Prodbox/ContainerImage.hs` now mirrors `postgres-operator` and `spilo-17` into Harbor and
  no longer carries Bitnami `repmgr` or `pgpool` targets on the supported path.
- `charts/keycloak-postgres/` now renders the Patroni cluster with three replicas, synchronous
  mode, explicit Spilo security IDs, and deterministic manual-PV bindings.
- `charts/keycloak/` now consumes the operator-generated database secret and the namespace-local
  primary service endpoint.
- The last completed Patroni-backed chart closure reruns remain the April 23, 2026 runs:
  `./.build/prodbox test unit`, `./.build/prodbox test integration charts-storage`,
  `./.build/prodbox test integration charts-platform`, and
  `./.build/prodbox test integration charts-vscode`, then the same Patroni-backed chart stack
  proof through `./.build/prodbox test integration all` and `./.build/prodbox test all`.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell `prodbox charts` surface.
- `documents/engineering/helm_chart_platform_doctrine.md` - Haskell chart runtime, supported stack
  topology, and the Patroni PostgreSQL doctrine.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding doctrine.
- `documents/engineering/local_registry_pipeline.md` - Harbor-loading implications for the chart
  platform where relevant.
- `documents/engineering/unit_testing_policy.md` - chart-platform integration ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the cluster-backed `vscode` path.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
