# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [system-components.md](system-components.md)

> **Purpose**: Capture the lifecycle hardening work, Pulumi decoupling work, and Python-removal
> work that leave one supported Haskell surface per major capability.

## Phase Summary

This phase closes the hard migration gap between parity and replacement. It ports lifecycle-critical
paths to Haskell, removes Python Pulumi programs, and deletes Python-specific toolchain ownership
from the repository. It owns Harbor-first lifecycle hardening, including the bootstrap exception
for Harbor and the HA-chart workloads required to make Harbor's storage backend functional, YAML
Pulumi definitions, and the repository-wide Python removal required for the supported Haskell
path.

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
- The current worktree now implements the corrected bootstrap split: Harbor installs first, MinIO
  bootstraps from public `quay.io/minio/*` refs so the local backend can come up, required public
  images and custom images are then populated into Harbor, and MinIO is reconciled back onto
  Harbor-backed refs for steady state.
- The canonical closure gates for this phase are the lifecycle rerun, Pulumi validations, the
  Harbor inventory and workload-source proofs, the bootstrap-source proof for Harbor and its
  storage-backend prerequisites, and repository-wide Python-removal checks.

## Sprint 4.1: Lifecycle Parity and Canonical-Path Closure on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Lib/`, `src/Prodbox/TestRunner.hs`, `pulumi/home/Main.yaml`, `test/integration/cli/Main.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the lifecycle-critical surfaces Haskell-only and close the Harbor-first multi-arch cluster
image contract without reintroducing Python or duplicate runtime paths.

### Deliverables

- The supported local lifecycle paths are Haskell-only.
- Harbor is installed and reconciled as the canonical cluster registry.
- Harbor and the HA-chart workloads required to make Harbor's storage backend functional may
  bootstrap from public container registries on the supported path.
- Every later cluster deployment obtains its images from Harbor.
- `prodbox` idempotently ensures required public images and all custom images are present in
  Harbor after bootstrap and before those later deployments.
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
6. Bootstrap source proof: Harbor and the HA-chart workloads needed for Harbor storage-backend
   readiness may pull from public registries on first bootstrap
7. Harbor inventory proof: required public images and custom images exist in Harbor for both
   `amd64` and `arm64` after bootstrap reconcile
8. Deployment source proof: post-bootstrap non-exception workloads reference Harbor on the
   supported path

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
  non-Harbor images already running in the cluster into Harbor, selecting from configured
  candidate sources and retrying alternate upstreams when Harbor publication fails after manifest
  inspection.
- `runNativeInstall` in `src/Prodbox/CLI/Rke2.hs` now performs the bootstrap split explicitly:
  public MinIO bootstrap first, Harbor population second, Harbor-backed MinIO steady-state
  reconcile third.
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
- `src/Prodbox/EffectInterpreter.hs` now validates the Pulumi-login prerequisite against the
  canonical repo-backed MinIO backend by port-forwarding MinIO, ensuring the backend bucket
  exists, and running `pulumi whoami` under the explicit backend environment used by the
  supported lifecycle instead of ambient host Pulumi state.
- `src/Prodbox/TestPlan.hs` maps `prodbox test integration lifecycle` to an executable native
  validation flow in `src/Prodbox/TestValidation.hs`.
- `prodbox rke2 delete --yes` now emits one summary-oriented cleanup narrative that reports AWS
  destroy disposition, local substrate cleanup, managed kubeconfig handling, and preserved roots
  without replaying successful Pulumi login output or uninstall-script trace noise.
- `test/integration/cli/Main.hs` now proves the split on the built-frontend path by recording both
  the public MinIO bootstrap refs, the publish-time fallback from
  `public.ecr.aws/docker/library/postgres` to `docker.io/library/postgres`, and the later
  Harbor-backed MinIO reconcile.
- `test/unit/Main.hs` now proves that the Pulumi prerequisite uses `withMinioPortForward`,
  `ensureMinioBackendBucket`, and `PULUMI_BACKEND_URL` on the supported path.
- The latest reruns now pass `prodbox check-code`, `prodbox test unit`,
  `prodbox test integration cli`, `prodbox test integration lifecycle`, `prodbox rke2 install`,
  and the aggregate `prodbox test all` flow that exercises the destructive lifecycle rerun and
  post-test Harbor restore on the corrected bootstrap order.
- The same reruns also pass the dependent phase gates `prodbox test integration env` and
  `prodbox test integration aws-iam`, so the corrected lifecycle order no longer blocks later
  validation.

### Remaining Work

None. The corrected Harbor/bootstrap split, alternate-source Harbor mirror retry, and the
canonical repo-backed Pulumi prerequisite are implemented and revalidated through
`prodbox rke2 install`, `prodbox test integration lifecycle`, and `prodbox test all`.

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
- `prodbox check-code` remains the canonical doctrine gate for this sprint.
- Repository text search across the root guidance docs and governed Sprint `1.2` docs is aligned
  with the Haskell-only repository state.
- `documents/engineering/pure_fp_standards.md` and
  `documents/engineering/refactoring_patterns.md` now describe Haskell-only purity, ADT, and
  boundary doctrine rather than Python-era examples.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is now empty; the
  Python-removal portion owned by Sprint `4.3` remains closed.

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
