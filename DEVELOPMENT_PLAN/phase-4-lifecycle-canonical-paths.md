# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [system-components.md](system-components.md)

> **Purpose**: Capture the lifecycle hardening work, Pulumi scope reduction, and Python-removal
> work that leave one supported Haskell surface per major capability.

## Phase Summary

This phase closes the hard migration gap between parity and replacement. It owns the Harbor-first
local lifecycle, the narrowed Harbor bootstrap doctrine, AWS-only Pulumi scope, the non-Python
Pulumi stack format, and the repository-wide Python removal that leaves the supported path
Haskell-only.

As of April 26, 2026, this phase is fully closed. Sprint `4.1`, Sprint `4.2`, and Sprint `4.3`
all pass on the updated lifecycle path. The lifecycle now keeps the Harbor-first bootstrap
doctrine intact while publishing lifecycle-managed custom images through the repo-owned
`ubuntu:24.04` Dockerfiles with in-image `ghcup`, pinned GHC `9.14.1`, no symlinked Haskell tool
shims, and no mounted `haskell-toolchain` BuildKit context.

## Current Baseline In Worktree

- `src/Prodbox/CLI/Rke2.hs` owns the supported local lifecycle.
- `src/Prodbox/ContainerImage.hs` owns the canonical Harbor targets, required public-image
  inventory, and ordered upstream-candidate lists used during Harbor publication.
- `src/Prodbox/CLI/Rke2.hs` now publishes frontend and gateway custom images directly through
  `docker buildx build --platform linux/amd64,linux/arm64 --push` and no longer defines the
  named BuildKit context `haskell-toolchain`.
- `src/Prodbox/CLI/Pulumi.hs` owns only the AWS validation IaC commands:
  `eks-resources|eks-destroy --yes|test-resources|test-destroy --yes`.
- `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and `pulumi/aws-test/Pulumi.yaml`
  plus `pulumi/aws-test/Main.yaml` are the only supported Pulumi stack programs; no supported
  local-cluster platform or application deployment depends on Pulumi.
- Python source, Python tests, Python packaging, Python type stubs, Python Pulumi programs, and
  Python bridge modules are removed from the repository.

## Sprint 4.1: Lifecycle Parity and Canonical-Path Closure on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/TestRunner.hs`, `test/integration/cli/Main.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the lifecycle-critical surfaces Haskell-only and close the Harbor-first cluster image
contract without reintroducing Python or duplicate runtime paths.

### Deliverables

- The supported local lifecycle path is Haskell-only.
- Harbor is installed and reconciled as the canonical local registry.
- Direct public-registry pulls occur only for Harbor and Harbor's storage backend before Harbor is
  healthy and externally serving.
- `prodbox` idempotently ensures required public images and all custom images are present in
  Harbor after Harbor bootstrap and before later Helm deployments run.
- Lifecycle-managed Haskell-build custom images stay single-stage `ubuntu:24.04`, install
  `ghcup` in-image, pin GHC `9.14.1`, and do not depend on mounted `haskell:9.6.7-slim`
  BuildKit contexts or symlinked Haskell tool shims.
- Every later Helm deployment obtains its images from Harbor.
- The lifecycle publishes or mirrors both `amd64` and `arm64` variants or manifests irrespective
  of the host architecture running `prodbox`.
- Harbor mirror publication retries alternate configured upstreams when a preferred source fails
  after manifest inspection.
- The explicit repo upgrade to GHC `9.14.1`, including required cabal-bound changes, closes with
  full canonical validation reruns on the upgraded toolchain path.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration lifecycle`
5. `prodbox rke2 delete --yes`
6. `prodbox rke2 install`
7. `prodbox dns check`
8. `prodbox host public-edge`
9. `prodbox test integration all`
10. `prodbox test all`

### Current Validation State

- `runNativeInstall` now performs the supported split explicitly: Harbor install and readiness
  first, Harbor-storage-backend bootstrap second, Harbor population and custom-image publication
  third, later Harbor-backed platform and chart workloads afterward.
- The Harbor readiness gate now requires both the external `/readyz` endpoint and the registry
  `/v2/` endpoint on `127.0.0.1:30080`, with six consecutive successful probe rounds before Docker
  login, mirror, or custom-image publication proceeds on a fresh cluster.
- `mirrorClusterImagesOnce` now reconciles the canonical required public images and any
  already-running non-Harbor cluster images into Harbor, selecting from configured candidate
  sources and retrying alternate upstreams when Harbor publication fails after manifest
  inspection.
- `ensureCustomImageVariants` now keeps the custom Haskell images single-stage while publishing
  `linux/amd64` and `linux/arm64` variants directly from the repo-owned Dockerfiles with no named
  `haskell-toolchain` context.
- `ensurePostgresOperatorRuntime` now removes an incompatible legacy Zalando
  `postgres-operator` release and deletes the dedicated operator namespace before installing the
  Percona operator, so retained clusters can transition onto the supported operator surface
  without hitting Helm's immutable Deployment selector error.
- `inspectRawImageManifest` in `src/Prodbox/CLI/Rke2.hs` now treats Harbor's `401 Unauthorized`
  response for a missing custom-image target as a build-required miss instead of a fatal inspect
  failure, so `prodbox rke2 install` rebuilds and publishes `prodbox-nginx-oidc` before later
  chart work resumes.
- On April 26, 2026, fresh reruns passed `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox dns check`, and `./.build/prodbox host public-edge`.
- On April 26, 2026, direct live chart and public-host reruns passed
  `./.build/prodbox test integration charts-platform`,
  `./.build/prodbox charts delete vscode --yes`,
  `./.build/prodbox charts deploy vscode`,
  `./.build/prodbox test integration charts-vscode`, and
  `./.build/prodbox test integration public-dns`, confirming that the lifecycle-owned cluster now
  closes again through Harbor bootstrap, Percona operator install, Route 53 bootstrap, and
  public-edge readiness.
- On April 26, 2026, the authoritative aggregate rerun `./.build/prodbox test all` passed after
  completing destructive delete, supported-runtime restore, `Validation: lifecycle`,
  destructive postflight teardown, and the final supported-runtime restore to
  `CLASSIFICATION=ready-for-external-proof`.

### Remaining Work

None.

## Sprint 4.2: Replace Python Pulumi Programs with Non-Python Pulumi Definitions ✅

**Status**: Done
**Implementation**: `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`

### Objective

Retain Pulumi as the IaC engine for AWS validation resources while removing Python and
local-cluster supported ownership from the Pulumi path.

### Deliverables

- Supported Pulumi stack programs are non-Python.
- Haskell owns Pulumi stack selection, config rendering, output parsing, and failure reporting.
- The AWS validation-stack paths continue to close through `prodbox pulumi ...`.
- No supported local-cluster platform or application deployment depends on Pulumi.
- No supported Pulumi program depends on Python.

### Validation

1. `prodbox pulumi eks-resources`
2. `prodbox pulumi eks-destroy --yes`
3. `prodbox pulumi test-resources`
4. `prodbox pulumi test-destroy --yes`
5. `prodbox test integration pulumi`
6. `prodbox test integration aws-eks`
7. `prodbox test integration ha-rke2-aws`

### Current Validation State

- `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and `pulumi/aws-test/Pulumi.yaml`
  plus `pulumi/aws-test/Main.yaml` are the retained AWS IaC programs.
- `src/Prodbox/CLI/Pulumi.hs` no longer exposes `up|preview|destroy|refresh|stack-init` for local
  cluster ownership; the public Pulumi surface is AWS-only.
- The AWS validation stack inputs are split by sensitivity: non-secret operator-CIDR and
  SSH-public-key values are synchronized through explicit Pulumi stack config written by the
  Haskell infra modules, while AWS provider credentials stay in `prodbox-config.dhall` and are
  projected into Pulumi through the Haskell-owned subprocess environment.
- On April 26, 2026, `./.build/prodbox pulumi eks-destroy --yes`, a fresh
  `./.build/prodbox test integration aws-eks`, and a second
  `./.build/prodbox pulumi eks-destroy --yes` passed after
  `src/Prodbox/Infra/AwsEksTestStack.hs` gained canonical unmanaged-residue purge before create
  and destroy when no saved snapshot exists.
- On April 26, 2026, the authoritative aggregate rerun `./.build/prodbox test all` passed after
  re-exercising the `aws-eks`, `pulumi`, and AWS HA-RKE2 create/destroy surfaces plus the final
  destructive postflight teardown.

### Remaining Work

None.

## Sprint 4.3: Repository-Wide Python Toolchain Removal ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/`, `prodbox.cabal`, `cabal.project`, `.gitignore`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/pure_fp_standards.md`, `documents/engineering/refactoring_patterns.md`

### Objective

Remove Python implementation and Python toolchain ownership from the repository once Haskell
parity exists.

### Deliverables

- Python source trees are deleted from the supported path.
- Python packaging metadata and Poetry ownership are removed.
- Python type stubs and pytest-specific harnesses are removed.
- `prodbox check-code` no longer shells out to Python-specific tooling.
- The Python-removal portion of the legacy ledger reaches zero pending items owned by this phase.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. Repository text-search proof shows that any remaining Python-era references are intentional and
   historical only.
4. Repository artifact-search proof shows that no supported-path Python implementation or Python
   toolchain artifacts remain.

### Current Validation State

- The repository no longer contains `src/prodbox/`, `tests/`, `typings/`, `pyproject.toml`,
  `poetry.toml`, `.python-version`, or any Python Pulumi program.
- `prodbox check-code` remains the canonical doctrine gate for this sprint.
- Root guidance docs and governed doctrine are aligned with the Haskell-only repository state.
- The Python-removal portion of
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is complete, and the ledger
  is now fully closed with no remaining pending-removal items.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - AWS validation environment and
  Pulumi boundary after local-cluster decoupling.
- `documents/engineering/aws_test_environment.md` - retained AWS validation environment doctrine.
- `documents/engineering/cli_command_surface.md` - canonical Haskell lifecycle and AWS-only Pulumi
  surface.
- `documents/engineering/code_quality.md` - final non-Python quality gate.
- `documents/engineering/dependency_management.md` - final Haskell dependency and container-image
  inventory, including the `ghcup` pin and no-symlink doctrine for Haskell-build containers.
- `documents/engineering/local_registry_pipeline.md` - Harbor-first lifecycle ordering and
  bootstrap doctrine.
- `documents/engineering/prerequisite_doctrine.md` - lifecycle and Pulumi prerequisite checks.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage contract after the
  lifecycle/chart rewrite.
- `documents/engineering/unit_testing_policy.md` - native lifecycle and aggregate validation
  ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep lifecycle and AWS IaC doctrine linked from [system-components.md](system-components.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [system-components.md](system-components.md)
