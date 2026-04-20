# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [system-components.md](system-components.md)

> **Purpose**: Capture the lifecycle hardening work, Pulumi decoupling work, and Python-removal
> work that leave one supported Haskell surface per major capability.

## Phase Summary

This phase closes the hard migration gap between parity and replacement. It ports lifecycle-critical
paths to Haskell, removes Python Pulumi programs, and deletes Python-specific toolchain ownership
from the repository. Those zero-Python outcomes remain done. Sprint `4.1` reopened on
April 18, 2026 and is now done: the lifecycle doctrine is implemented in the worktree with
Harbor-only workload sourcing, idempotent required-public-image population, first-class `amd64`
plus `arm64` handling, mixed-arch-aware image publication, and a passing destructive lifecycle
rerun on the updated implementation.

## Current Baseline In Worktree

- Native Haskell runtime ownership covers the full lifecycle and Pulumi surface. All Python
  lifecycle, Pulumi, and quality-gate code have been removed from the repository.
- `src/Prodbox/CLI/Rke2.hs` owns `prodbox rke2 install|delete|status|start|stop|restart|logs`
  including the current Harbor, MinIO, and image-reconcile baseline.
- `src/Prodbox/ContainerImage.hs` owns the canonical Harbor registry constants, supported public
  image inventory, and Harbor target mapping used by the lifecycle and chart platform.
- `src/Prodbox/CLI/Pulumi.hs` owns `prodbox pulumi up|preview|destroy|refresh|stack-init` and
  routes `eks-resources|eks-destroy|test-resources|test-destroy` through native Haskell infra
  modules.
- All Pulumi programs are YAML-based: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, and
  `pulumi/aws-test/Main.yaml`. The root `Pulumi.yaml` uses `runtime: yaml`.
- The AWS validation Pulumi programs take their operator-CIDR and SSH-public-key inputs through
  explicit stack config synchronized by the native Haskell infra modules rather than YAML-runtime
  `std:getenv` provider lookups.
- `CheckCode.hs` runs `cabal build --builddir=.build all` without Python tooling.
- All Python source (`src/prodbox/`), Python tests (`tests/`), Python type stubs (`typings/`),
  and Python packaging (`pyproject.toml`, `poetry.toml`, `.python-version`) have been deleted.
- Harbor now installs before MinIO on the supported path, MinIO is deployed from Harbor-backed
  image references, required public images are reconciled idempotently into Harbor, and custom
  images publish through explicit dual-arch `buildx` flows.
- The canonical host-side build, doctrine gate, and Phase `1` validation reruns now pass on this
  host after restoring the missing ncurses development linker dependency.

## Sprint 4.1: Lifecycle Parity and Canonical-Path Closure on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Lib/`, `src/Prodbox/TestRunner.hs`, `pulumi/home/Main.yaml`, `test/integration/cli/Main.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the lifecycle-critical surfaces Haskell-only and close the Harbor-first multi-arch cluster
image contract without reopening Python or duplicate runtime paths.

### Deliverables

- The supported local lifecycle paths are Haskell-only.
- Harbor is installed and reconciled as the canonical cluster registry.
- Harbor is the only service allowed to bootstrap directly from Docker Hub.
- Every other cluster deployment obtains its images from Harbor.
- `prodbox` idempotently ensures required public images and all custom images are present in
  Harbor before deployment.
- The supported lifecycle path publishes, mirrors, loads, or fetches both `amd64` and `arm64`
  image variants or manifests irrespective of local host architecture.
- Mixed-arch clusters are supported on the canonical lifecycle, gateway, and chart-delivery path.
- Canonical-path cleanup keeps one supported surface per capability and records any temporary
  residue in the legacy ledger.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration lifecycle`
4. `prodbox rke2 delete --yes`
5. `prodbox rke2 install`
6. Harbor inventory proof: required public images and custom images exist in Harbor for both
   `amd64` and `arm64`
7. Deployment source proof: non-Harbor workloads reference Harbor-only images on the supported
   path

### Current Validation State

- The supported local lifecycle paths remain Haskell-only on the runtime surface.
- Harbor install, project reconcile, and Docker login or push flow exist in the native lifecycle.
- `src/Prodbox/ContainerImage.hs` defines the canonical required-public-image inventory and
  Harbor-backed targets used by the supported lifecycle and chart path.
- `src/Prodbox/Infra/AwsEksTestStack.hs` and `src/Prodbox/Infra/AwsTestStack.hs` now synchronize
  AWS validation stack inputs through `pulumi config set`, and `pulumi/aws-eks/Main.yaml` plus
  `pulumi/aws-test/Main.yaml` consume those values as explicit stack config instead of
  `std:getenv`.
- `mirrorClusterImagesOnce` now reconciles both the canonical required public images and the
  non-Harbor images already running in the cluster into Harbor.
- The Harbor bootstrap path now waits for both the external `/readyz` endpoint and the registry
  `/v2/` endpoint on `127.0.0.1:30080` before attempting Docker login.
- The Harbor bootstrap path now also requires six consecutive successful `/readyz` plus `/v2/`
  probe rounds before Docker login, image mirror, or custom-image publication continues on a fresh
  cluster.
- `ensureCustomImageVariants` now keeps the final Haskell images single-stage while mounting the
  official `haskell:9.6.7-slim` toolchain image as a BuildKit context, publishes custom images
  separately for `linux/amd64` and `linux/arm64`, composes the final manifest with
  `docker buildx imagetools create`, creates the `docker-container` buildx builder with host
  networking so Harbor pushes to `127.0.0.1:30080` work from inside the builder, installs the
  official AWS CLI bundle inside the single-stage gateway image per `TARGETARCH`, and then
  re-imports the host-architecture variant into RKE2.
- Selector-scoped Kubernetes metadata reconcile in the lifecycle path now renders either `-l ...`
  or `--all`, never the invalid `-l ... --all` combination.
- `pulumi/home/Main.yaml` and the chart platform now point supported shared infrastructure and app
  workloads at Harbor-backed image references.
- `src/Prodbox/TestPlan.hs` maps `prodbox test integration lifecycle` to an executable native
  validation flow in `src/Prodbox/TestValidation.hs`.
- `prodbox rke2 delete --yes` now emits one summary-oriented cleanup narrative that reports AWS
  destroy disposition, local substrate cleanup, managed kubeconfig handling, and preserved roots
  without replaying successful Pulumi login output or uninstall-script trace noise.
- The host linker prerequisite is cleared, and `cabal run --builddir=.build exe:prodbox -- test
  integration lifecycle` now passes on this host, re-closing validation items `1-7` on the
  updated Harbor-first lifecycle path.

### Remaining Work

None.

## Sprint 4.2: Replace Python Pulumi Programs with Non-Python Pulumi Definitions ✅

**Status**: Done
**Implementation**: `Pulumi.yaml`, `pulumi/`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`

### Objective

Retain Pulumi as the infrastructure engine while removing Python from the supported Pulumi path.

### Deliverables

- Existing Python Pulumi stack programs and runtime declarations are replaced with non-Python
  Pulumi definitions.
- Haskell owns Pulumi stack selection, config rendering, output parsing, and failure reporting.
- Both the local-cluster infrastructure path and the AWS validation-stack paths continue to close
  through `prodbox pulumi ...`.
- No supported Pulumi program depends on Python after this sprint closes.

### Validation

1. `prodbox pulumi preview`
2. `prodbox pulumi up --yes`
3. `prodbox pulumi destroy --yes`
4. `prodbox test integration pulumi`
5. `prodbox test integration aws-eks`
6. `prodbox test integration ha-rke2-aws`

### Current Validation State

- All supported Pulumi programs are YAML-based, and the public Pulumi runtime surface is
  Haskell-owned.
- `src/Prodbox/TestPlan.hs` maps `prodbox test integration pulumi`, `aws-eks`, and
  `ha-rke2-aws` to executable native validation flows in `src/Prodbox/TestValidation.hs`.

### Remaining Work

None. All Python Pulumi programs are replaced with YAML definitions:
`pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml`. Root
`Pulumi.yaml` uses `runtime: yaml`.

## Sprint 4.3: Repository-Wide Python Toolchain Removal ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/`, `prodbox.cabal`, `cabal.project`, `.gitignore`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/pure_fp_standards.md`, `documents/engineering/refactoring_patterns.md`

### Objective

Remove Python implementation and Python toolchain ownership from the repository once Haskell parity
exists.

### Deliverables

- Python source trees are deleted from the supported path.
- Python packaging metadata and Poetry ownership are removed.
- Python type stubs and pytest-specific harnesses are removed.
- `prodbox check-code` no longer shells out to Python-specific tooling.
- The Python-removal portion of the legacy ledger reaches zero pending items owned by this phase.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. Repository text-search proof shows that any remaining Python-era architecture references are
   intentional and tracked in the legacy ledger.
4. Repository artifact-search proof shows that no supported-path Python implementation or Python
   toolchain artifacts remain.

### Current Validation State

- The repository no longer contains `src/prodbox/`, `tests/`, `typings/`, `pyproject.toml`,
  `poetry.toml`, `.python-version`, or any Python Pulumi program.
- `prodbox check-code` remains the canonical doctrine gate and now passes on this host again.
- Repository text search across the root guidance docs and governed Sprint `1.2` docs is aligned
  with the Haskell-only repository state.
- `documents/engineering/pure_fp_standards.md` and
  `documents/engineering/refactoring_patterns.md` now describe Haskell-only purity, ADT, and
  boundary doctrine rather than Python-era examples.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is empty in `Pending Removal`
  again.

### Remaining Work

None. All Python source (`src/prodbox/`, `tests/`, `typings/`), Python packaging
(`pyproject.toml`, `poetry.toml`, `.python-version`), and Python bridge modules have been deleted.
`CheckCode.hs` runs `cabal build --builddir=.build all` without Python tooling.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/storage_lifecycle_doctrine.md` - lifecycle parity and retained-root
  contract on the Haskell stack.
- `documents/engineering/local_registry_pipeline.md` - Harbor-first registry, public-image
  population, dual-arch publication, and mixed-arch doctrine.
- `documents/engineering/aws_integration_environment_doctrine.md` - retained AWS and Pulumi rules
  without Python.
- `documents/engineering/aws_test_environment.md` - supported AWS validation after Python Pulumi
  removal.
- `documents/engineering/cli_command_surface.md` - canonical Haskell lifecycle and Pulumi surface.
- `documents/engineering/code_quality.md` - Haskell-owned quality gate.
- `documents/engineering/dependency_management.md` - Cabal ownership, Docker doctrine, and Python
  toolchain removal.
- `documents/engineering/integration_fixture_doctrine.md` - cluster-backed integration doctrine
  after pytest-specific ownership is removed.
- `documents/engineering/prerequisite_doctrine.md` - lifecycle prerequisites, Harbor bootstrap,
  and mixed-arch host expectations.
- `documents/engineering/pure_fp_standards.md` - repository coding standards once Python-specific
  examples and tooling assumptions are gone.
- `documents/engineering/refactoring_patterns.md` - retire or rewrite Python-specific migration
  guidance that no longer matches the supported architecture.
- `documents/engineering/unit_testing_policy.md` - lifecycle, Pulumi, and mixed-arch validation
  ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep Python-removal ownership linked back to
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [system-components.md](system-components.md)
