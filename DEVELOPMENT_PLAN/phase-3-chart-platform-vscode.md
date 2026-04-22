# Phase 3: Haskell Chart Platform and Cluster-Backed `vscode` Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell chart platform, deterministic retained storage model, and the
> supported cluster-backed `vscode` delivery path.

## Phase Summary

This phase ports the chart platform and retained-storage orchestration to Haskell while preserving
namespace-local stack composition, deterministic PV or PVC rebinding, and the supported
cluster-backed `vscode` delivery model. It owns retained storage, Harbor-backed image sourcing for
the supported chart stack, and the `vscode-nginx` image exception under the repository Docker
doctrine.

## Current Baseline In Worktree

- The public `prodbox charts ...` runtime lives in `src/Prodbox/CLI/Charts.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Lib/Storage.hs`. All Python chart code has
  been removed from the repository.
- Retained roots remain the configured manual PV root (default `.data/`) and `.prodbox-state/`;
  chart secret resolution and gateway event-key handling are Haskell-owned.
- The custom `vscode-nginx` image build lives in `docker/nginx-oidc.Dockerfile`.
- `docker/nginx-oidc.Dockerfile` remains based on `nginx:1.25-alpine`, and the supported stack
  now references Harbor-backed `vscode-nginx`, `code-server`, `keycloak`, and `postgres` images.
- `src/Prodbox/TestPlan.hs` maps the chart validation names to executable native validations in
  `src/Prodbox/TestValidation.hs`.
- The canonical closure gates for this phase are the named chart-platform and retained-storage
  validation flows.

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
  `src/Prodbox/Lib/Storage.hs` own the default public Haskell runtime for
  `prodbox charts list|status|deploy|delete`, including deterministic retained storage,
  repo-local secret or event-key retention, Helm deploy or delete orchestration, and chart status
  rendering.
- `src/Prodbox/TestRunner.hs` supported-runtime bootstrap and postflight invoke native Haskell
  `prodbox charts ...` surfaces instead of calling retained backend chart commands directly.
- `test/unit/Main.hs` proves deterministic Haskell chart-plan and storage-binding behavior, and
  `test/integration/cli/Main.hs` proves native built-frontend `prodbox charts
  list|status|deploy|delete` behavior against fake `helm` and `kubectl`.
- All Python chart code has been removed. The Haskell chart runtime is the sole owner of
  `prodbox charts list|status|deploy|delete`.
- The named validation commands in this sprint (`prodbox test integration charts-storage` and
  `prodbox test integration charts-platform`) run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.

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

- The namespace-local `keycloak-postgres -> keycloak -> vscode` stack remains the supported app
  path.
- `vscode-nginx` remains the namespace-local auth proxy behind Traefik.
- `vscode-nginx` may remain based on `nginx:1.25-alpine`, but it is loaded into Harbor before
  deployment and referenced from Harbor on the supported path.
- The Haskell chart runtime owns deploy, status, and delete behavior for the `vscode` stack.
- Both `amd64` and `arm64` variants of the auth-proxy image are published or loaded irrespective
  of the architecture of the machine running `prodbox`.
- Unsupported local-dev or non-cluster delivery paths remain absent from the supported
  architecture.

### Validation

1. `prodbox test integration charts-platform`
2. `prodbox test integration charts-vscode`
3. Image source proof: the supported chart or rendered manifests reference Harbor for
   `vscode-nginx`
4. Harbor proof: both `amd64` and `arm64` variants of the auth-proxy image are available

### Current Validation State

- The supported cluster-backed `vscode` delivery path remains Haskell-owned in the chart runtime
  and chart assets.
- `src/Prodbox/TestPlan.hs` maps `prodbox test integration charts-vscode` to an executable native
  validation flow in `src/Prodbox/TestValidation.hs`, and that suite remains on the
  supported-runtime bootstrap path rather than bypassing the cluster runbook.
- The later aggregate chart validations now operate on the singleton chart stack already restored
  by the supported-runtime bootstrap: `charts-platform` proves `charts list|status` on the
  installed `vscode` path, and `charts-storage` proves retained-storage reporting before deleting
  the root `vscode` stack instead of attempting singleton-violating redeploys.
- `docker/nginx-oidc.Dockerfile` already lives in `docker/`, and the Alpine-base exception remains
  permitted for this image.
- `src/Prodbox/CLI/Rke2.hs` now publishes `vscode-nginx` through the dual-arch Harbor-backed
  custom-image flow.
- `src/Prodbox/CLI/Pulumi.hs` now projects configured ZeroSSL EAB credentials into the
  `cert-manager` namespace as `acme-eab-credentials` and wires the supported `ClusterIssuer`
  through `spec.acme.externalAccountBinding` when `acme.eab_*` values are set.
- `src/Prodbox/Lib/ChartPlatform.hs` and the chart defaults now point the supported
  `keycloak-postgres -> keycloak -> vscode` stack at Harbor-backed `postgres`, `keycloak`,
  `code-server`, and `vscode-nginx` image references.
- The current worktree also carries the gateway chart or runtime fixes surfaced by the
  `charts-vscode` path: repo-rootless gateway startup, env-secret AWS auth, HTTP `/v1/state`
  health probes, and the single-stage gateway image's official AWS CLI bundle install.
- `src/Prodbox/TestRunner.hs` now waits for `prodbox host public-edge` to report
  `CLASSIFICATION=ready-for-external-proof` during supported-runtime bootstrap and postflight
  before the external `charts-vscode` curl proof continues.
### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell `prodbox charts` surface.
- `documents/engineering/helm_chart_platform_doctrine.md` - Haskell chart runtime, supported stack
  topology, and Harbor-backed auth-proxy image doctrine.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding doctrine.
- `documents/engineering/local_registry_pipeline.md` - container-build and Harbor-loading
  implications for the chart platform where relevant.
- `documents/engineering/unit_testing_policy.md` - chart-platform integration ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the cluster-backed `vscode` path.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
