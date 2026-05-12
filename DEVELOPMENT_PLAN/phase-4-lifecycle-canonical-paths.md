# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[system-components.md](system-components.md), [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)

> **Purpose**: Capture the lifecycle hardening work, Pulumi scope reduction, Python-removal
> work, and the CLI-doctrine adoption sprints that bring the local-cluster lifecycle and AWS
> validation surfaces in line with [../HASKELL_CLI_TOOL.md →
> Reconcilers](../HASKELL_CLI_TOOL.md) and `Test Organization`.

## Phase Status

🔄 **Active** — Sprints `4.1`–`4.4` remain `Done` on lifecycle parity, Python Pulumi removal,
repository-wide Python toolchain removal, and the single-record DNS / single-certificate
contract. The phase is reopened by Sprint 0.2 to schedule Sprints `4.5`–`4.7`: rename
`prodbox rke2 install` → `prodbox rke2 reconcile` per doctrine, apply the Plan / Apply +
`--dry-run` discipline (Sprint 1.7) to the lifecycle reconcile, and migrate AWS-validation
infrastructure tests into a dedicated `prodbox-pulumi` cabal test stanza. Current worktree
evidence closes Sprints `4.5` and `4.6`: `prodbox rke2 reconcile` is now the canonical
entrypoint, the deprecated `install` alias preserves only the old name, the lifecycle plan is
golden-covered, and the governed docs and validation call sites now reference `reconcile`.
Sprint `4.7` is `Active`: the dedicated Pulumi stanza exists and passes locally as a scaffold,
but the real ephemeral-stack lifecycle proof is still pending.

## Phase Summary

This phase closes the hard migration gap between parity and replacement. It owns the Harbor-first
local lifecycle, the narrowed Harbor bootstrap doctrine, the public AWS-validation Pulumi surface,
the non-Python Pulumi stack format, and the repository-wide Python removal that leaves the
supported path Haskell-only. Sprints `4.2` and `4.3` remain closed on the AWS-validation Pulumi
surface and repository-wide Python removal. Sprint `4.1` now also closes on the authoritative
Harbor-plus-storage-backend bootstrap contract. The supported lifecycle and retained AWS-validation stacks
otherwise close on clean-room-only behavior, native-host-architecture Docker publication, one
Route 53 record, and one listener certificate for `test.resolvefintech.com`.

## Current Baseline In Worktree

- `src/Prodbox/CLI/Rke2.hs` owns the supported local lifecycle.
- `src/Prodbox/ContainerImage.hs` owns the canonical Harbor targets, required public-image
  inventory, and ordered upstream-candidate lists used during Harbor publication.
- `src/Prodbox/CLI/Rke2.hs` publishes frontend and gateway custom images through ordinary
  host-native Docker build and push flows with no supported `buildx` dependency.
- `src/Prodbox/CLI/Pulumi.hs` owns only the AWS validation IaC commands:
  `eks-resources|eks-destroy --yes|test-resources|test-destroy --yes`.
- `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and `pulumi/aws-test/Pulumi.yaml`
  plus `pulumi/aws-test/Main.yaml` are the only supported public Pulumi stack programs; broad
  local-cluster platform or application ownership no longer depends on Pulumi.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS validation stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile through
  `deployment.pulumi_enable_dns_bootstrap` plus ACME `ClusterIssuer` projection; these helpers do
  not expand the public `prodbox pulumi ...` surface.
- The authoritative lifecycle target keeps Harbor plus Harbor's storage backend as the only direct-
  public bootstrap exception before later Harbor-backed workloads proceed. `runNativeInstall` now
  installs MinIO first, bootstraps the Harbor registry bucket plus secret through the public
  `quay.io/minio/*` storage-backend images, and then reconciles Harbor on S3-backed registry
  storage before later Harbor image publication resumes.
- The lifecycle-owned DNS and certificate helpers now close on the one-record or one-cert
  doctrine for the shared public edge.
- `src/Prodbox/CLI/Rke2.hs` closes the supported lifecycle on the clean-room Harbor, Envoy
  Gateway, cert-manager, and Percona reconcile path with no retained Traefik or pre-Percona
  operator cleanup shims.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs with no legacy Pulumi provider-config
  cleanup path.
- Python source, Python tests, Python packaging, Python type stubs, Python Pulumi programs, and
  Python bridge modules are removed from the repository.

## Sprint 4.1: Lifecycle Parity and Canonical-Path Closure on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/TestRunner.hs`, `test/integration/cli/Main.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the lifecycle-critical surfaces Haskell-only and close the Harbor-first cluster image
contract without reintroducing Python, duplicate runtime paths, or cross-arch container builds.

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
- Supported custom-image publication uses ordinary host-native Docker builds and pushes rather
  than `docker buildx`.
- `amd64` hosts publish only `amd64` images, and `arm64` hosts publish only `arm64` images.
- Native `arm64` publication works on native `arm64` Docker daemons without requiring cross-arch
  emulation.
- Every later Helm deployment obtains its images from Harbor.
- Mixed-arch cluster closure and cross-arch manifest publication are unsupported on the canonical
  lifecycle path.
- Harbor mirror publication retries transient Harbor availability failures on the same candidate
  and then retries alternate configured upstreams when a preferred source still fails after
  manifest inspection.
- The explicit repo upgrade to GHC `9.14.1`, including required cabal-bound changes, closes with
  full canonical validation reruns on the upgraded toolchain path.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration lifecycle`
5. `prodbox rke2 delete --yes`
6. `prodbox rke2 reconcile`
7. `prodbox dns check`
8. `prodbox host public-edge`
9. `prodbox test integration all`
10. `prodbox test all`

### Current Validation State

- The authoritative lifecycle target keeps the supported split explicit: Harbor-storage-backend
  bootstrap first, Harbor install configured to use that backend plus readiness second, Harbor
  population and custom-image publication third, and later Harbor-backed platform and chart
  workloads afterward.
- `runNativeInstall` now deploys MinIO before Harbor, bootstraps the Harbor registry bucket plus
  credential secret through the supported public `quay.io/minio/*` storage-backend path, and
  reconciles Harbor with S3-backed `persistence.imageChartStorage` values before mirror, custom-
  image publication, or later Harbor-backed platform work continues.
- The shared Helm repo-update and upgrade/install helpers in `src/Prodbox/CLI/Rke2.hs` now retry
  transient upstream chart-fetch failures before surfacing a hard lifecycle failure, so the
  supported clean-room rerun can absorb intermittent upstream `5xx` and timeout errors.
- The Harbor readiness gate now requires both the external `/readyz` endpoint and the registry
  `/v2/` endpoint on `127.0.0.1:30080`, with six consecutive successful probe rounds before Docker
  login, mirror, or custom-image publication proceeds on a fresh cluster.
- `mirrorClusterImagesOnce` now reconciles the canonical required public images and any
  already-running non-Harbor cluster images into Harbor, selecting from configured candidate
  sources, retrying transient Harbor publication failures on the same candidate, and then
  retrying alternate upstreams when Harbor publication still fails after manifest inspection. The
  configured candidate set now includes `mirror.gcr.io` fallbacks for the Docker Hub-hosted
  Percona and Envoy images used by the supported lifecycle, so clean-room reruns can absorb
  unauthenticated Docker Hub rate limiting without leaving the Harbor-first doctrine.
- `ensureCustomImageVariants` keeps the custom Haskell images single-stage and now publishes only
  the native architecture of the host through ordinary `docker build` plus `docker push`.
- `ensureClusterPlatformRuntime` now reconciles the supported MetalLB, Envoy Gateway,
  cert-manager, ACME, and Percona operator surfaces directly with no retained cluster-migration
  cleanup shims for Traefik or the earlier incompatible operator surface.
- `supportedHostArchitecture`, `harborTargetAvailableForHostArchitecture`, and
  `pushDockerImageWithRetry` in `src/Prodbox/CLI/Rke2.hs` now detect the supported native host
  architecture, decide whether Harbor already has the required image, and publish or retry only
  that architecture before later chart work resumes.

### Remaining Work

None.

## Sprint 4.2: Replace Python Pulumi Programs with Non-Python Pulumi Definitions ✅

**Status**: Done
**Implementation**: `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`

### Objective

Retain Pulumi as the IaC engine for AWS validation resources while removing Python and broad
local-cluster supported ownership from the public Pulumi path.

### Deliverables

- Supported Pulumi stack programs are non-Python.
- Haskell owns Pulumi stack selection, config rendering, output parsing, and failure reporting.
- The AWS validation-stack paths continue to close through `prodbox pulumi ...`.
- AWS validation local state remains repo-local under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`.
- No supported root `Pulumi.yaml`, `pulumi/home`, or broad local-cluster public operator flow
  depends on Pulumi.
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
  cluster ownership; the public Pulumi surface is AWS-validation-only.
- `src/Prodbox/CLI/Rke2.hs` retains bootstrap DNS reconcile and ACME `ClusterIssuer` projection
  on the lifecycle path rather than on the public `prodbox pulumi ...` surface.
- The AWS validation stack inputs are split by sensitivity: non-secret operator-CIDR and
  SSH-public-key values are synchronized through explicit Pulumi stack config written by the
  Haskell infra modules, while AWS provider credentials stay in `prodbox-config.dhall` and are
  projected into Pulumi through the Haskell-owned subprocess environment.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` retain stack
  snapshots under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/`, and the
  HA-RKE2 validation SSH key stays under `.prodbox-state/aws-test/`.
- The retained AWS validation stack helpers now write only the supported operator-CIDR and
  SSH-public-key inputs and no longer remove older Pulumi provider-key layouts on the supported
  path.

### Remaining Work

None.

## Sprint 4.3: Repository-Wide Python Toolchain Removal ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `prodbox.cabal`, `cabal.project`, `.gitignore`
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
- The repository search checks in this sprint remain explicit repo-review gates alongside the
  implemented `prodbox` command-surface validations.
- Root guidance docs and governed doctrine are aligned with the Haskell-only repository state.
- The Python-removal portion of
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is complete, and the ledger
  remains closed on Python-removal residue.

### Remaining Work

None.

## Sprint 4.4: Single-Record DNS Bootstrap and Single-Certificate Lifecycle Closure ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the lifecycle-owned bootstrap DNS and TLS surfaces on the one-host doctrine:
`test.resolvefintech.com`, one Route 53 record, and one certificate for all public or admin
routes behind Envoy.

### Deliverables

- Lifecycle-owned bootstrap DNS reconcile writes only the canonical `test.resolvefintech.com`
  record.
- Lifecycle-owned certificate projection and listener configuration require only one public
  certificate for the shared Envoy edge.
- No supported lifecycle path assumes dedicated identity, browser, API, or WebSocket hostnames.
- The Harbor-first lifecycle preserves Envoy, MetalLB, and cert-manager ownership while switching
  the public edge to the one-record or one-cert contract.

### Validation

1. `prodbox check-code`
2. `prodbox test integration lifecycle`
3. `prodbox rke2 reconcile`
4. `prodbox host public-edge`
5. `prodbox test integration public-dns`
6. `prodbox test all`

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` owns bootstrap DNS reconcile and ACME `ClusterIssuer` projection on
  the supported lifecycle path.
- Those helpers now write only the canonical `test.resolvefintech.com` record and keep the
  lifecycle-owned certificate contract on one public listener certificate for the shared Envoy
  edge.

### Remaining Work

None.

## Sprint 4.5: Rename `prodbox rke2 install` → `prodbox rke2 reconcile` ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/TestRunner.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/local_registry_pipeline.md`, `CLAUDE.md`, `README.md`, `AGENTS.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Reconcilers: Idempotent Mutation as a Single
Command](../HASKELL_CLI_TOOL.md) on the canonical local-cluster lifecycle entrypoint.

### Deliverables

- Introduce `prodbox rke2 reconcile` as the canonical idempotent reconcile entrypoint that
  owns install, repair, and drift reconciliation on the supported self-managed cluster path.
- Keep `prodbox rke2 install` as a hard-deprecation alias for exactly one cycle that emits a
  doctrine pointer on `stderr` and execs the reconcile path. Enqueue the alias in the legacy
  ledger with the owning sprint and target removal cycle.
- Update CLAUDE.md, root `README.md`, AGENTS.md, governed engineering docs, Pulumi
  orchestration call sites, integration tests, and any documentation referencing the old name.
- Sprint 0.4 round-3 extension: apply the same forbidden-flag and
  sister-command discipline to the lifecycle reconciler per
  [../HASKELL_CLI_TOOL.md → Reconcilers → Forbidden
  Patterns](../HASKELL_CLI_TOOL.md) §1781–1803. `prodbox rke2 reconcile` refuses
  the literal flag names `--force` and `--reinstall` at parse time; no
  `prodbox rke2 upgrade`, `prodbox rke2 repair`, or `prodbox rke2 force-install`
  sister command is added. The one-cycle deprecation alias preserves
  `prodbox rke2 install` only as an alias that calls the reconciler; it does not
  preserve any of the forbidden flags (an operator who passes `--force` to the
  alias receives the same parse-time rejection as on the canonical
  `reconcile` entrypoint). A `prodbox-unit` parser test asserts the rejection
  for both `install` and `reconcile`.

### Validation

1. `prodbox rke2 reconcile` is fully idempotent across repeated runs.
2. `prodbox rke2 install` continues to work for one cycle and emits the deprecation pointer.
3. No supported-path documentation refers to `install` as the canonical name after the rename.

### Remaining Work

None.

## Sprint 4.6: Lifecycle Plan / Apply + --dry-run ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Rke2.hs`
**Docs to update**: `documents/engineering/local_registry_pipeline.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Apply [../HASKELL_CLI_TOOL.md → Plan / Apply](../HASKELL_CLI_TOOL.md) (Sprint 1.7) to the
lifecycle reconcile.

### Deliverables

- `prodbox rke2 reconcile --dry-run` renders the full subprocess, Helm, Pulumi, and Kubernetes
  plan and exits `0` without mutation.
- Each existing reconcile step under `src/Prodbox/CLI/Rke2.hs` adopts the doctrine's
  check-before-mutate shape literally.

### Validation

1. Golden tests cover the rendered lifecycle plan.
2. Re-running `prodbox rke2 reconcile` after a successful run performs zero mutating work.

### Remaining Work

None.

## Sprint 4.7: prodbox-pulumi Test Stanza 🔄

**Status**: Active
**Implementation**: `prodbox.cabal`, `test/pulumi/Main.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_test_environment.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Pulumi-Orchestrated Infrastructure
Tests](../HASKELL_CLI_TOOL.md) and `Test Organization`.

### Deliverables

- New `test-suite prodbox-pulumi` stanza with `type: exitcode-stdio-1.0`. Move the AWS-IaC
  validation flows (`aws-eks`, `aws-test`, HA-RKE2) into the stanza. Each run uses an
  isolated ephemeral stack, generates a unique stack name, and tears down via `bracket` /
  `finally`.
- Pulumi outputs flow as the typed contract between provisioning and test execution.

### Validation

1. `cabal test prodbox-pulumi` provisions, tests, and tears down successfully.
2. No leaked stacks survive a failing run; `bracket` cleanup is verified by a forced-failure
   test.

### Remaining Work

- The `prodbox-pulumi` Cabal stanza now exists and passes locally, but it is still a scaffold
  suite that checks repository ownership of the YAML Pulumi programs and parser surface.
- The doctrine-owned ephemeral-stack behavior is still absent: isolated stack creation,
  typed-output handoff into test execution, and forced-failure cleanup proof remain to be
  implemented.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - AWS validation environment and
  Pulumi boundary after broad local-cluster decoupling.
- `documents/engineering/aws_test_environment.md` - retained AWS validation environment doctrine.
- `documents/engineering/cli_command_surface.md` - canonical Haskell lifecycle and public
  AWS-validation Pulumi surface.
- `documents/engineering/code_quality.md` - final non-Python quality gate.
- `documents/engineering/dependency_management.md` - final Haskell dependency and container-image
  inventory, including the `ghcup` pin and no-symlink doctrine for Haskell-build containers.
- `documents/engineering/local_registry_pipeline.md` - Harbor-first lifecycle ordering and the
  authoritative Harbor-plus-storage-backend bootstrap doctrine.
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
