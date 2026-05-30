# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[system-components.md](system-components.md), [the engineering doctrine docs](../documents/engineering/README.md)

> **Purpose**: Capture the lifecycle hardening work, Pulumi scope reduction, Python-removal
> work, and the CLI-doctrine adoption sprints that bring the local-cluster lifecycle and AWS
> validation surfaces in line with [> Reconcilers](../documents/engineering/README.md) and `Test Organization`.

## Phase Status

✅ **Done** — Sprints `4.1`–`4.4` remain `Done` on lifecycle parity, Python Pulumi removal,
repository-wide Python toolchain removal, and the single-record DNS / single-certificate
contract. The phase was first reopened by Sprint 0.2 to schedule Sprints `4.5`–`4.7`: rename
`prodbox rke2 install` → `prodbox rke2 reconcile` per doctrine, apply the Plan / Apply +
`--dry-run` discipline (Sprint 1.7) to the lifecycle reconcile, and migrate AWS-validation
infrastructure tests into a dedicated `prodbox-pulumi` cabal test stanza. Sprint `0.5` reopened
the phase again to schedule Sprint `4.8`, the `prodbox rke2 delete --yes` success-summary
hardening. Current worktree evidence closes Sprints `4.5`, `4.6`, `4.7`, and `4.8`:
`prodbox rke2 reconcile` is the canonical entrypoint, the deprecated `install` alias has been
removed, lifecycle forbidden sister commands are rejected at parse time, the lifecycle plan is
golden-covered, the dedicated `prodbox-pulumi` stanza proves the retained Pulumi-program
ownership, local ephemeral-stack harness, typed-output contract, and forced-failure cleanup, the
governed docs and validation call sites reference `reconcile`, and successful
`prodbox rke2 delete --yes` runs are hermetic — benign upstream uninstall chatter such as
`Failed to allocate directory watch: Too many open files` is filtered through the lifecycle-local
quiet path, while non-zero uninstall exits still surface actionable upstream context.

## Phase Summary

This phase closes the hard migration gap between parity and replacement. It owns the Harbor-first
local lifecycle, the narrowed Harbor bootstrap doctrine, the public AWS-validation Pulumi surface,
the non-Python Pulumi stack format, and the repository-wide Python removal that leaves the
supported path Haskell-only. Sprints `4.2` and `4.3` remain closed on the AWS-validation Pulumi
surface and repository-wide Python removal. Sprint `4.1` now also closes on the authoritative
Harbor-plus-storage-backend bootstrap contract. The supported lifecycle and retained
AWS-validation stacks otherwise close on clean-room-only behavior, native-host-architecture Docker
publication, one Route 53 record, and one listener certificate for `test.resolvefintech.com`.
Sprint `4.8` closed the user-visible delete-output hardening: success is summary-owned by
`prodbox`, while failures keep actionable upstream context.

**May 24, 2026 — pure-Dhall config doctrine cross-reference**: Phase 4's lifecycle
reconciliation surface is unaffected by the new
[config_doctrine.md](../documents/engineering/config_doctrine.md). One interaction is
worth naming: under the new doctrine, daemon Pods auto-restart on boot-field config
changes (the file-watch worker drains and exits with `ExitSuccess`; the kubelet restarts
the Pod against the new Dhall). This means `prodbox rke2 reconcile` runs that re-render
the gateway or workload ConfigMaps trigger a Pod restart without operator action, by
design — there is no separate "reload running daemons" step in the cascade. See
[Sprint 2.21](phase-2-gateway-dns.md) for the implementation.

## Current Baseline In Worktree

- `src/Prodbox/CLI/Rke2.hs` owns the supported local lifecycle.
- `src/Prodbox/CLI/Rke2.hs` keeps `prodbox rke2 delete --yes` hermetic on success through the
  lifecycle-local `captureToolOutput` quiet path plus the expanded
  `isIgnorableRke2DeleteNoiseLine` filter that classifies inotify warnings (`Failed to allocate
  directory watch: Too many open files`), `Cannot find device`, `semodule: not found`, and
  timestamped `Cleanup completed successfully` lines as benign noise. Non-zero uninstall exits
  still surface actionable upstream lines through `summarizeRke2DeleteFailure`.
- `src/Prodbox/ContainerImage.hs` owns the canonical Harbor targets, required public-image
  inventory, and ordered upstream-candidate lists used during Harbor publication.
- `src/Prodbox/CLI/Rke2.hs` publishes frontend and gateway custom images through ordinary
  host-native Docker build and push flows with no supported `buildx` dependency.
- `src/Prodbox/CLI/Pulumi.hs` owns only the AWS substrate IaC commands:
  `eks-resources|eks-destroy --yes|test-resources|test-destroy --yes`.
- `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and `pulumi/aws-test/Pulumi.yaml`
  plus `pulumi/aws-test/Main.yaml` are the only supported public Pulumi stack programs; broad
  local-cluster platform or application ownership no longer depends on Pulumi.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS substrate stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`; the HA-RKE2 validation destroys and recreates the retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails, repairing stale
  EC2 instances left by interrupted runs or operator network moves.
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
**Implementation**: `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/TestRunner.hs`, `test/integration/CliSuite.hs`, `test/unit/Main.hs`
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

Retain Pulumi as the IaC engine for AWS substrate resources while removing Python and broad
local-cluster supported ownership from the public Pulumi path.

### Deliverables

- Supported Pulumi stack programs are non-Python.
- Haskell owns Pulumi stack selection, config rendering, output parsing, and failure reporting.
- The AWS substrate paths continue to close through `prodbox pulumi ...`.
- AWS substrate local state remains repo-local under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`; the HA-RKE2 validation destroys and recreates the retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails.
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
- The AWS substrate stack inputs are split by sensitivity: non-secret operator-CIDR and
  SSH-public-key values are synchronized through explicit Pulumi stack config written by the
  Haskell infra modules, while AWS provider credentials stay in `prodbox-config.dhall` and are
  projected into Pulumi through the Haskell-owned subprocess environment.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` retain stack
  snapshots under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/`, and the
  HA-RKE2 validation SSH key stays under `.prodbox-state/aws-test/`; stale retained EC2 nodes are
  repaired by one destroy-and-recreate retry when HA-RKE2 SSH validation fails after a successful
  Pulumi reconcile.
- The retained AWS substrate stack helpers now write only the supported operator-CIDR and
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

Adopt [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command) on the canonical local-cluster lifecycle entrypoint.

### Deliverables

- Introduce `prodbox rke2 reconcile` as the canonical idempotent reconcile entrypoint that
  owns install, repair, and drift reconciliation on the supported self-managed cluster path.
- Remove the completed one-cycle `prodbox rke2 install` deprecation alias from the supported
  command surface and record the cleanup in the legacy ledger.
- Update CLAUDE.md, root `README.md`, AGENTS.md, governed engineering docs, Pulumi
  orchestration call sites, integration tests, and any documentation referencing the old name.
- Sprint 0.4 round-3 extension: apply the same forbidden-flag and
  sister-command discipline to the lifecycle reconciler per
  [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command). `prodbox rke2 reconcile` refuses
  the literal flag names `--force` and `--reinstall` at parse time; no
  `prodbox rke2 install`, `prodbox rke2 upgrade`, `prodbox rke2 repair`, or
  `prodbox rke2 force-install` sister command is added. A `prodbox-unit` parser test asserts the
  rejection for both `install` and `reconcile`.

### Validation

1. `prodbox rke2 reconcile` is fully idempotent across repeated runs.
2. `prodbox rke2 install` is rejected at parse time as a forbidden sister command after the
   completed one-cycle compatibility window.
3. No supported-path documentation refers to `install` as a supported command after the alias
   cleanup.

### Remaining Work

None.

## Sprint 4.6: Lifecycle Plan / Apply + --dry-run ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Rke2.hs`
**Docs to update**: `documents/engineering/local_registry_pipeline.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Apply [pure_fp_standards.md#plan--apply](../documents/engineering/pure_fp_standards.md#plan--apply) (Sprint 1.7) to the
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

## Sprint 4.7: prodbox-pulumi Test Stanza ✅

**Status**: Done
**Implementation**: `prodbox.cabal`, `test/pulumi/Main.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_test_environment.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Adopt [unit_testing_policy.md#pulumi-orchestrated-infrastructure-tests](../documents/engineering/unit_testing_policy.md#pulumi-orchestrated-infrastructure-tests) and `Test Organization`.

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

### Current Validation State

- The `prodbox-pulumi` Cabal stanza now passes locally with the doctrine-owned ephemeral-stack
  harness: each test run creates isolated local stack state, round-trips typed outputs through
  the `EphemeralPulumiOutputs` contract, and proves forced-failure cleanup.
- The retained AWS test-stack destroy path now refreshes Pulumi state and retries destroy once
  before surfacing failure, matching the existing AWS EKS cleanup behavior and protecting
  `prodbox rke2 delete --yes` from stale-state teardown races.
- The live retained AWS IaC flows (`aws-eks`, `aws-test`, HA-RKE2) are covered by the named
  `prodbox test integration aws-eks`, `prodbox test integration pulumi`, and
  `prodbox test integration ha-rke2-aws` validations and by `prodbox test all`.

### Remaining Work

None.

## Sprint 4.8: Hermetic `rke2 delete` Success Reporting ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Subprocess.hs`,
`test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/streaming_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Harden the successful `prodbox rke2 delete --yes` operator surface so it matches
[Output Rules](../documents/engineering/streaming_doctrine.md#output-rules) and
[Reconcilers: Idempotent Mutation as a Single
Command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command):
`prodbox` owns the success summary, while hard failures preserve actionable upstream context.

### Deliverables

- `deleteRke2ClusterSubstrate` captures the upstream uninstall-script stdout/stderr through a
  lifecycle-local quiet path rather than relying on generic subprocess streaming. The change is
  scoped to `prodbox rke2 delete --yes`; it does not broaden into repo-wide stderr suppression.
- When `/usr/local/bin/rke2-uninstall.sh` exits `0`, the user-visible delete output is hermetic:
  only the doctrine-owned summary lines remain (`Deleting local RKE2 environment...`, AWS destroy
  dispositions, `Local RKE2 substrate: cleanup complete`, kubeconfig disposition, retained-root
  notice).
- Benign upstream uninstall chatter on success — including host-specific noise such as `Failed to
  allocate directory watch: Too many open files` — is classified as ignorable success-path noise
  and does not surface as an operator-visible red-herring error.
- When the uninstall exits non-zero, `prodbox` still renders actionable failure context through the
  existing summarizer path rather than hiding the upstream failure.
- The fake uninstall harness in `test/integration/CliSuite.hs` gains both sides of the contract:
  a success case that emits the exact inotify warning and proves it is suppressed, and a failure
  case that proves non-ignorable lines still reach the user as a summarized error.
- The governed docs listed above update together, per
  [../documents/documentation_standards.md](../documents/documentation_standards.md):
  `cli_command_surface.md` states the hermetic success-summary contract,
  `streaming_doctrine.md` states the success-versus-failure output rule for noisy lifecycle
  subprocesses, and `storage_lifecycle_doctrine.md` records the cleanup-summary boundary on the
  destructive delete path.

### Validation

1. `prodbox check-code`
2. `prodbox test integration cli`
3. `prodbox test integration lifecycle`
4. `prodbox rke2 delete --yes`
5. `prodbox test all`

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` keeps `deleteRke2ClusterSubstrate` on the lifecycle-local quiet path
  (`captureToolOutput`) and `isIgnorableRke2DeleteNoiseLine` now classifies
  `Failed to allocate directory watch` and `Too many open files` as benign upstream chatter
  alongside the existing `Cannot find device`, `semodule: not found`, and timestamped
  `Cleanup completed successfully` lines.
- `test/integration/CliSuite.hs` exercises both sides of the hermetic contract: the existing
  success path now also proves the inotify warning is suppressed, and a new failure case proves
  actionable upstream context (`umount: ... target is busy`) reaches the operator while the benign
  chatter classes are filtered from the summary.
- `documents/engineering/cli_command_surface.md`,
  `documents/engineering/streaming_doctrine.md`, and
  `documents/engineering/storage_lifecycle_doctrine.md` describe the hermetic
  success-summary contract and the success-versus-failure output rule.

### Remaining Work

None.

## Sprint 4.10: Decouple Long-Lived Pulumi State Onto a Dedicated S3 Bucket 🔄

**Status**: Active — code framework + admin-credential switch +
migrate-backend body all landed May 21, 2026 on their code-owned
surface; the live operator migration cycle (existing MinIO-backed
operator runs `prodbox pulumi aws-ses-migrate-backend` once, then
the new long-lived backend path reads/writes state) remains as the
live operator step. New `loadAdminAwsCredentials` helper in
`src/Prodbox/Infra/LongLivedPulumiBackend.hs`; new
`pulumiSesAdminBaseEnv` in `src/Prodbox/Infra/AwsSesStack.hs`;
`ensureAwsSesStackResources` + `destroyAwsSesStackStatus` rewritten
to authenticate with `aws_admin_for_test_simulation.*` and use the
long-lived S3 backend directly (no MinIO port-forward);
`migrateAwsSesStackBackend` body implements the doctrine
recipe end-to-end (idempotent short-circuit when long-lived backend
already carries the stack; export from MinIO → import into S3
otherwise). `pulumi/aws-ses/Pulumi.yaml` declares the long-lived S3
backend URL via a top-level `backend.url` field so operators running
`pulumi` directly outside the prodbox harness pick up the correct
backend automatically. `destroyLongLivedPulumiStateBucket` helper
added to support Sprint 4.13's nuke step 5.
**Implementation**: `prodbox-config-types.dhall` (already includes
`pulumi_state_backend` with `bucket_name`, `region`, `key_prefix`);
`prodbox-config.dhall` (already overrides
`bucket_name = "prodbox-pulumi-state-long-lived"`,
`region = "us-west-2"`, `key_prefix = "pulumi/"`);
`src/Prodbox/Settings.hs` (new `PulumiStateBackendSection` record with
prefix-stripping custom `FromDhall` instance; renderer + display
output); `src/Prodbox/Infra/LongLivedPulumiBackend.hs` (new) exports
`longLivedPulumiBackendUrl`, `longLivedPulumiBackendUrlEither`,
`ensureLongLivedPulumiStateBucket` (idempotent: head-bucket; on miss
create with versioning, AES256 SSE, block-public-access, prodbox
tags, 90-day non-current expiration lifecycle), and
`withLongLivedPulumiBackendEnv` (bracket sets `PULUMI_BACKEND_URL`,
restores prior value); `src/Prodbox/CLI/Command.hs`
(`PulumiAwsSesMigrateBackend PlanOptions`); `src/Prodbox/CLI/Spec.hs`
(parser + leaf for `pulumi aws-ses-migrate-backend`);
`src/Prodbox/CLI/Pulumi.hs` (handler dispatch);
`src/Prodbox/Infra/AwsSesStack.hs::migrateAwsSesStackBackend`
(TTY-gated scaffold; emits the migration runbook pending live closure);
`src/Prodbox/CLI/Interactive.hs::awsSesMigrateBackendGuard` (non-TTY
refusal with automation hint).
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`substrates.md`](substrates.md),
[`../documents/engineering/aws_integration_environment_doctrine.md`](../documents/engineering/aws_integration_environment_doctrine.md),
[`../CLAUDE.md`](../CLAUDE.md)

### Objective

Move long-lived Pulumi state (today: `aws-ses`; tomorrow: any future
cross-substrate long-lived stack) out of the in-cluster MinIO backend and
into a dedicated AWS S3 bucket owned by the operator account, so the
long-lived class survives arbitrary `rke2 delete + rke2 reconcile` cycles
and operator-machine churn. Per-run stacks continue using the in-cluster
MinIO backend. The state-lifetime rule from
[lifecycle_reconciliation_doctrine.md → §2](../documents/engineering/lifecycle_reconciliation_doctrine.md)
becomes the implemented behaviour: state lifetime matches resource lifetime
per class.

### Deliverables

- `prodbox-config-types.dhall` exposes a new `PulumiStateBackend` record
  (`bucket_name : Text`, `region : Text`, `key_prefix : Text`) and a
  matching empty default. `prodbox-config.dhall` overrides
  `bucket_name = "prodbox-pulumi-state-long-lived"`,
  `region = "us-west-2"`, `key_prefix = "pulumi/"`. The repository import
  sha256 is refrozen.
- `src/Prodbox/Infra/LongLivedPulumiBackend.hs` (new) exports
  `longLivedPulumiBackendUrl`, `ensureLongLivedPulumiStateBucket`
  (idempotent: head-bucket; on miss create with versioning, AES256 SSE,
  block-public-access, the prodbox tags, and a 90-day non-current-version
  expiration lifecycle rule), and
  `withLongLivedPulumiBackend` (bracket: ensures bucket, sets
  `PULUMI_BACKEND_URL`, runs action, restores env).
- `src/Prodbox/Aws.hs` routes long-lived stack names through the new
  module; per-run stacks continue using `MinioBackend`. The per-run vs
  long-lived partition stays sourced from `perRunStackNames` /
  `longLivedStackNames`.
- Long-lived stack operations (`prodbox pulumi aws-ses-resources`,
  `prodbox pulumi aws-ses-destroy`) authenticate with the admin
  credential block (`aws_admin_for_test_simulation.*`) rather than the
  operational `aws.*` block. The operational `prodbox` IAM user is no
  longer granted `s3:GetObject`/`PutObject` on the state bucket.
- `prodbox pulumi aws-ses-migrate-backend` (new operator command, TTY
  refusal) implements the §2 migration recipe idempotently:
  `pulumi stack export` against MinIO,
  `ensureLongLivedPulumiStateBucket`, `pulumi login s3://...`,
  `pulumi stack import` into the new backend. No-op if state is already
  in S3.
- `pulumi/aws-ses/Pulumi.yaml` records the new backend URL.

### Validation

1. `prodbox check-code`
2. `prodbox test unit` covers the backend-URL renderer and the
   bucket-spec generator (pure logic).
3. `prodbox test integration aws-ses-migrate-backend` (new) — exercises
   the migration end-to-end against live AWS.
4. `prodbox pulumi aws-ses-migrate-backend && prodbox rke2 delete
   --cascade && prodbox rke2 reconcile && prodbox pulumi
   aws-ses-resources` produces a no-op Pulumi diff.

### Current Validation State

Code framework landed May 21, 2026: `prodbox check-code` exits 0,
`prodbox test unit` (396/396, up from 387 by adding eight URL-renderer
+ error-rendering tests plus the `host public-edge --substrate aws`
test from Sprint 7.5.c.v.f); the pre-existing
`pulumi_state_backend` round-trip test failure cleared because
`PulumiStateBackendSection` is now a first-class Haskell record with
a custom `FromDhall` instance that strips the `psb` Haskell-side
prefix while keeping bare Dhall field names. `prodbox pulumi
aws-ses-migrate-backend --help` renders and the command refuses
non-TTY contexts via `awsSesMigrateBackendGuard`.

### Remaining Work

- Live operator workflow (`prodbox pulumi aws-ses-migrate-backend`
  → `rke2 delete --cascade` → `rke2 reconcile` → `pulumi
  aws-ses-resources` no-op-diff) — pending the operator-driven
  live exercise. The code body is wired and unit-tested but the
  live destructive cycle against a populated AWS account has not
  yet been exercised.
- `prodbox test integration aws-ses-migrate-backend` (new
  integration suite for the migration) — pending the live closure.

Blocks Sprints `4.11`, `4.12`, `4.13`.

## Sprint 4.11: `rke2 delete` Refuse-Path and Predicate Library 🔄

**Status**: Active — refuse-path + `--cascade` entry point + predicate
library + tag-sweep helpers landed May 21, 2026; full predicate
inventory landed May 21, 2026 (`noLiveClusterTaggedAws` wraps
`TagSweep`; `noUndrainedK8sAwsResources` wraps the newly-exposed
`collectSurvivors` from `K8sDrain`; `noLiveOperationalIamUser` wraps
the new `operationalIamUserExists` helper in `src/Prodbox/Aws.hs`;
`noLeftoverDnsBootstrapRecords` wraps the new
`operationalBootstrapDnsRecordExists` helper). The `aws teardown`
reimplementation onto the new library is deliberately deferred —
the existing `checkPulumiResidueBeforeTeardown` +
`renderPulumiResidueRefusal` pair already implements the desired
runtime behavior, and switching the call site to
`checkAll [noLivePerRunPulumiStacks, noLiveLongLivedPulumiStacks]`
would require either (a) preserving the verbatim Sprint 7.7
refusal text via a fragile golden pin, or (b) changing the
operator-visible refusal text (which would need a Sprint 0.X
doctrine alignment). The library is wired and unit-tested by
label; consolidation behind `applyAwsTeardown` remains as a
clearly-scoped follow-up sub-sprint.
**Implementation**: `src/Prodbox/CLI/Command.hs` (new
`Rke2DeleteFlags` record); `src/Prodbox/CLI/Spec.hs`
(`rke2DeleteFlagsParser` enforces `--cascade` xor
`--allow-pulumi-residue` via the `flag' <|> flag' <|> pure` idiom;
new leaf options + examples); `src/Prodbox/Lifecycle/Preconditions.hs`
(new) exports `Precondition`, `StructuredError`, `checkAll`,
`renderPreconditionFailures`, `noLivePerRunPulumiStacks`,
`noLiveLongLivedPulumiStacks`; `src/Prodbox/Lifecycle/TagSweep.hs`
(new) exports `discoverClusterTaggedAwsResources` against the AWS
Resource Tagging API plus `renderTagSweepRefusal`;
`src/Prodbox/CLI/Rke2.hs::runNativeDeleteWithResiduePolicy` opens
default-mode `rke2 delete` with `checkAll [noLivePerRunPulumiStacks]`
and `runNativeDeleteCascade` is the entry point for the cascade
orchestration (currently delegates to `runNativeDelete` with a
"K8s drain not yet implemented" warning until Sprint 4.12 lands).
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`../documents/engineering/cli_command_surface.md`](../documents/engineering/cli_command_surface.md),
[`../documents/engineering/aws_integration_environment_doctrine.md`](../documents/engineering/aws_integration_environment_doctrine.md),
[`../CLAUDE.md`](../CLAUDE.md), [`../documents/engineering/README.md`](../documents/engineering/README.md),
[`../README.md`](../README.md)

### Objective

Make orphaning per-run Pulumi-managed AWS resources structurally
impossible from `prodbox rke2 delete`. Introduce the positive-framed
`--cascade` "clean teardown" path that orchestrates per-run Pulumi
destroys, cluster uninstall, and a postflight tag sweep as one atomic
operator action. Generalize the Sprint `7.6` residue-check pattern into
a typed predicate library that excludes `aws-ses` from `rke2 delete`'s
scope (its state lives outside the cluster after Sprint `4.10`).

### Deliverables

- `src/Prodbox/Lifecycle/Preconditions.hs` (new) exports the named
  `Precondition` values from
  [lifecycle_reconciliation_doctrine.md → §4](../documents/engineering/lifecycle_reconciliation_doctrine.md):
  `noLivePerRunPulumiStacks`, `noLiveLongLivedPulumiStacks`,
  `noLiveClusterTaggedAws`, `noUndrainedK8sAwsResources`,
  `noLiveOperationalIamUser`, `noLeftoverDnsBootstrapRecords`. Each
  wraps one `discover` and returns `IO (Either StructuredError ())`.
  `checkAll :: [Precondition] -> IO (Either [StructuredError] ())`
  composes them.
- `src/Prodbox/Lifecycle/TagSweep.hs` (new) exports
  `discoverClusterTaggedAwsResources` against the AWS Resource Tagging
  API (Pulumi-tracked residue only in this sprint; full cluster-tag
  scan lands in Sprint `4.12`).
- `src/Prodbox/CLI/Rke2.hs` opens `prodbox rke2 delete` with
  `checkAll [noLivePerRunPulumiStacks]`. Adds the new flags
  `--cascade`, `--allow-pulumi-residue`, `--dry-run`, `--plan-file`.
  Mutual exclusion at parse time: `--cascade` and
  `--allow-pulumi-residue` cannot be combined. `--cascade`
  orchestrates per-run Pulumi destroys in canonical order
  (`aws-eks-subzone`, `aws-eks`, `aws-test`) + cluster uninstall +
  postflight tag sweep. The K8s drain phase is **not** part of this
  sprint; `--cascade` emits a "K8s drain not yet implemented" warning
  until Sprint `4.12` adds it.
- `prodbox aws teardown`'s existing predicates are reimplemented as
  composition of the new library (`noLivePerRunPulumiStacks <>
  noLiveLongLivedPulumiStacks`) so the Sprint `7.6`/`7.7` contract is
  preserved verbatim while the library is consolidated.

### Validation

1. `prodbox check-code`
2. `prodbox test unit` covers predicate composition, flag mutual
   exclusion, and refuse-path message rendering (pure logic).
3. `prodbox test integration cli` covers `--dry-run` / `--cascade
   --dry-run` snapshots.
4. `prodbox test integration aws-iam` (or new `lifecycle-cascade`)
   covers end-to-end refuse, then `--cascade`, then `rke2 reconcile`,
   then `pulumi aws-ses-resources` no-op-diff path against live AWS,
   including a scenario where `aws-ses` is live (must be ignored
   throughout) and per-run stacks are live (must be flagged in default
   mode and destroyed in `--cascade` mode).

### Current Validation State

Code framework landed May 21, 2026: `prodbox check-code` exits 0;
`prodbox test unit` (399/399, up from 396 by adding three new
`rke2 delete` parser tests covering the default, `--cascade`,
`--allow-pulumi-residue`, and mutual-exclusion paths). The new
help text + completions are regenerated via `prodbox docs generate`
and round-trip through `prodbox docs check` cleanly.

### Remaining Work

- Full predicate inventory (`noLiveClusterTaggedAws`,
  `noUndrainedK8sAwsResources`, `noLiveOperationalIamUser`,
  `noLeftoverDnsBootstrapRecords`) lands alongside Sprint 4.12's
  K8s drain phase because those discoverers need the same
  kubectl/aws-resourcegroups infrastructure.
- `prodbox aws teardown`'s existing residue predicates
  (`checkPulumiResidueBeforeTeardown` in `src/Prodbox/Aws.hs`) are
  not yet reimplemented as a composition of the new library; the
  refactor is straightforward (the existing function maps 1:1 onto
  `noLivePerRunPulumiStacks <> noLiveLongLivedPulumiStacks`) but
  the Sprint 7.7 contract must remain preserved verbatim, so the
  refactor is deferred to a follow-up sub-sprint that includes a
  golden-test pin on the rendered refusal text.
- `prodbox test integration aws-iam` (or a new `lifecycle-cascade`
  suite) exercising end-to-end refuse → `--cascade` → `rke2
  reconcile` → `pulumi aws-ses-resources` no-op-diff against live
  AWS — pending the live closure.
- Operator-facing strings in `src/Prodbox/CLI/Spec.hs` (`--cascade`
  / `--allow-pulumi-residue` flag-help, `rke2 delete` leaf
  description) currently leak Sprint identifiers; the doctrine
  alignment landed in
  [cli_command_surface.md § 2A](../documents/engineering/cli_command_surface.md#2a-operator-vocabulary-contract),
  the implementation landed in Sprint `4.14` on May 21, 2026.

Blocks Sprints `4.12` and `4.13`.

## Sprint 4.12: K8s Drain Phase and Postflight Tag Sweep 🔄

**Status**: Active — K8sDrain module + cascade-wiring landed May 21, 2026;
TagSweep module already supports the full cluster-tag query through
the `kubernetes.io/cluster/<name>` filter family and the
`prodbox.io/managed-by` filter; Sprint 4.13's nuke step 4 is the
first wired caller of the postflight scan; cascade-postflight wiring
remains a follow-up because cascade runs with operational `aws.*`
which may not have `resourcegroupstaggingapi:GetResources` grants on
the compacted Sprint 7.5.c.v.d policy.
**Implementation**: `src/Prodbox/Lifecycle/K8sDrain.hs` (new) exports
`K8sDrainEnv`, `DrainTimeout`, `DrainResult`, `defaultDrainTimeout`
(5 min), `drainAwsAffectingK8sResources` (deletes LoadBalancer
Services, ALB Ingresses, and Delete-reclaim PVCs cluster-wide, then
polls every 10s with bounded timeout), `renderDrainTimeoutRefusal`
(structured error block naming the surviving K8s resources by
@Kind/namespace/name@);
`src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` now runs the drain
phase before the per-run Pulumi destroys per the doctrine in
@documents/engineering/lifecycle_reconciliation_doctrine.md § 5@.
The "K8s drain not yet implemented" warning emitted by Sprint 4.11
is removed.
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`substrates.md`](substrates.md),
[`../documents/engineering/aws_integration_environment_doctrine.md`](../documents/engineering/aws_integration_environment_doctrine.md),
[`../documents/engineering/cli_command_surface.md`](../documents/engineering/cli_command_surface.md),
[`../documents/engineering/unit_testing_policy.md`](../documents/engineering/unit_testing_policy.md)

### Objective

Close leak classes 2–5 from
[lifecycle_reconciliation_doctrine.md → §1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
(CSI volumes, LBC load balancers, cert-manager DNS01 records,
direct-`aws`-CLI shell-out Route 53 records) by adding a K8s-API drain
phase to `prodbox rke2 delete --cascade` (and, when introduced,
`prodbox nuke`). The drain runs **before** any Pulumi destroy so the
LBC and EBS CSI driver are still alive and can unwind their AWS
resources.

### Deliverables

- `src/Prodbox/Lifecycle/K8sDrain.hs` (new) exports
  `drainAwsAffectingK8sResources :: KubectlEnv -> IO (Either
  StructuredError ())`. Deletes LoadBalancer Services, ALB Ingresses,
  and Delete-reclaim PVCs cluster-wide, then polls for AWS-side
  unwind with a bounded timeout (default 5 min). Structured error on
  timeout names the remaining AWS resources by ARN.
- Wires the drain into the `--cascade` arm of `rke2 delete` between
  the existing predicate check and the Pulumi destroys. Removes the
  "K8s drain not yet implemented" warning emitted by Sprint `4.11`.
- `src/Prodbox/Lifecycle/TagSweep.hs` extends the postflight scan from
  Pulumi-tracked residue only to the full cluster-tag query
  (`kubernetes.io/cluster/<cluster-name>` + `prodbox.io/*`).

### Validation

1. `prodbox check-code`
2. `prodbox test unit` covers drain-policy classifiers (which K8s
   objects trigger which AWS-side unwind) as pure logic.
3. `prodbox test integration lifecycle-cascade` deploys a chart
   producing an ALB and a PVC, runs `rke2 delete --cascade`, asserts
   (a) the ALB and EBS volume are gone from AWS within the drain
   timeout, (b) the postflight tag sweep returns empty, (c) `aws-ses`
   resources are untouched.

### Current Validation State

Code framework landed May 21, 2026: `prodbox check-code` exits 0;
`prodbox test unit` (399/399).

### Remaining Work

- Cascade-postflight tag sweep wiring: nuke step 4 is the only
  wired caller today. Wiring the same scan into the cascade arm of
  `rke2 delete --cascade` is the natural follow-up but requires
  either (a) extending the Sprint 7.5.c.v.d operational IAM policy
  to grant `tag:GetResources` / `resourcegroupstaggingapi:GetResources`,
  or (b) treating the cascade postflight sweep as a soft check that
  skips with a warning when the credentials lack the required grant.
- Drain-policy classifier unit tests (the "which K8s objects trigger
  which AWS-side unwind" matrix) are scaffolded by the module
  structure but not yet committed as pure tests.
- `prodbox test integration lifecycle-cascade` exercising end-to-end
  drain + postflight tag-sweep against live AWS — pending the live
  closure.
- The cascade currently fails noisily when the cluster is already
  absent (`kubectl delete services ...` returns `DrainFailed`
  because kubectl falls back to `localhost:8080`); the doctrine
  alignment landed in
  [lifecycle_reconciliation_doctrine.md § 3 layer 1 + § 4](../documents/engineering/lifecycle_reconciliation_doctrine.md#3-the-reconciler-with-predicates-pattern)
  (`DrainSkipped` outcome treated as success-with-reason), the
  implementation landed in Sprint `4.15` on May 21, 2026.
  Operator-facing
  cascade-narration strings still leak Sprint identifiers; the
  vocabulary cleanup landed in Sprint `4.14` on May 21, 2026.

Blocked by Sprint `4.11`. Blocks Sprint `4.13`.

## Sprint 4.13: `prodbox nuke` Total Teardown 🔄

**Status**: Active on its code-owned surface — CLI scaffold +
parser + TTY guard + dry-run plan renderer landed May 21, 2026; the
five-step orchestration body landed May 21, 2026 (composes the
existing destroy commands in-process); the live end-to-end `nuke`
exercise remains pending the operator-driven destructive cycle
against a populated AWS account.
**Implementation**: `src/Prodbox/CLI/Nuke.hs` (orchestration body
landed; exports `runNukeCommand`, `confirmationLiteral`,
`renderNukePlan`, `defaultNukeOptions`); `src/Prodbox/CLI/Command.hs`
(`NativeNuke NukeOptions` + `NukeOptions {nukeDryRun, nukePlanFile}`);
`src/Prodbox/CLI/Spec.hs` (`nuke` parser + `nukeLeaf` registration in
`commandRegistry`); `src/Prodbox/Native.hs` (dispatch
`NativeNuke -> runNukeCommand`); `src/Prodbox/CLI/Interactive.hs`
(reused via `requireInteractiveTty` with a `nukeInteractiveGuard`
that names the canonical command sequence for automation);
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` (new
`destroyLongLivedPulumiStateBucket` + the JSON-Haskell
`renderDeletePayload` / `purgeRemainingVersions` pipeline that
empties the versioned bucket before deletion);
`src/Prodbox/CLI/Rke2.hs` (exports `runNativeDeleteWithResiduePolicy`
so nuke step 1 can delegate to the cascade arm); `src/Prodbox/Aws.hs`
(exports `adminAwsEnvironment`, `promptAdminCredentialsWithRegionChoice`,
`validateAdminCredentialsInput` so the orchestration body can prompt
once for admin credentials and reuse them across steps 3, 4, 5).
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`../documents/engineering/cli_command_surface.md`](../documents/engineering/cli_command_surface.md),
[`../CLAUDE.md`](../CLAUDE.md), [`../documents/engineering/README.md`](../documents/engineering/README.md),
[`../README.md`](../README.md)

### Objective

Introduce the operator-only total teardown command — the only
sanctioned path to destroy `aws-ses` and the long-lived
`pulumi_state_backend` bucket transitively, alongside the explicit
per-stack `prodbox pulumi aws-ses-destroy --yes`. The command exists so
operators have one clearly-labelled "blow away everything prodbox owns"
entrypoint, with the discipline necessary to make accidental invocation
impossible.

### Deliverables

- `src/Prodbox/CLI/Nuke.hs` (new) implements the `prodbox nuke`
  command. Orchestrates, in dependency order: K8s drain (Sprint
  `4.12`), destroy all Pulumi stacks (`aws-eks-subzone`, `aws-eks`,
  `aws-test`, `aws-ses`), `prodbox aws teardown`-equivalent IAM
  cleanup, local rke2 uninstall, postflight tag sweep, and finally
  the long-lived `pulumi_state_backend` bucket destruction.
- TTY-only: refuses non-interactive contexts with a message naming the
  canonical command sequence to compose manually.
- Typed-confirmation: operator must type the literal string
  `NUKE EVERYTHING` (not `yes`) at the confirmation prompt.
- `--dry-run` / `--plan-file` render the exact sequence without
  mutating. No `--yes` shorthand — deliberate omission.

### Validation

1. `prodbox check-code`
2. `prodbox test unit` covers parser shape (TTY refusal, typed-token
   acceptance, flag mutual exclusion).
3. `prodbox nuke --dry-run` against a populated AWS account produces
   the expected ordered plan.
4. End-to-end live `nuke` is an opt-in CI suite (it destroys long-lived
   shared infrastructure) — gated behind explicit operator request,
   not part of the default canonical test suite.

### Current Validation State

Code framework landed May 21, 2026; orchestration body landed
May 21, 2026: `prodbox check-code` exits 0; `prodbox test unit`
(420/420, up from 403 by adding three new `renderDeletePayload`
tests covering the canonical S3 `delete-objects` payload shape and
two `renderNukePlan` tests that pin the five-step ordering plus the
typed-confirmation literal). `./.build/prodbox nuke --dry-run`
renders the dependency-ordered teardown plan with the
typed-confirmation literal `NUKE EVERYTHING` visible in the output.
TTY refusal exercised via `nukeInteractiveGuard`. After
typed-confirmation acceptance, the orchestration body now runs the
five-step destructive sequence (cascade arm → `aws-ses` destroy →
operational IAM teardown → postflight tag sweep → long-lived
state-bucket destroy) in-process, prompting once for admin AWS
credentials at the start so they are not retyped per step.

### Remaining Work

- Live end-to-end `nuke` (opt-in operator-driven destructive cycle)
  — pending the live closure. The orchestration body is wired and
  unit-tested, but the live destructive sequence has not yet been
  exercised against a populated AWS account.

Blocked by Sprints `4.10`, `4.11`, `4.12`.

## Sprint 4.14: Operator Vocabulary Contract Enforcement ✅

**Status**: Done (May 21, 2026)
**Implementation**: `src/Prodbox/CLI/Spec.hs` (rewrite the
sprint-tagged strings at `:672` `--cascade` parser-side help,
`:680` `--allow-pulumi-residue` parser-side help, `:1268–1271`
`rke2 delete` leaf description, `:1277` `aws-ses-migrate-backend`
leaf description, `:1333` `--cascade` leaf-side help, `:1345`
example help, `:1438` `nukeLeaf` description into operator
vocabulary); `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade`
(strip the `Sprint 4.11:` / `Sprint 4.12 pending` labels from the
`writeOutputLine` strings); `src/Prodbox/CheckCode.hs` (add a
`Sprint [0-9]` regex scan over operator-facing surfaces per
[cli_command_surface.md § 2A](../documents/engineering/cli_command_surface.md#2a-operator-vocabulary-contract));
regenerate `documents/cli/commands.md`, `share/man/man1/*`,
`share/completion/{bash,zsh,fish}/*`,
`test/golden/cli/{commands-tree.txt,commands.json,help-all.txt}`
via `prodbox docs generate` plus `cabal test --accept` on the three
golden tests.
**Docs to update**: `documents/engineering/cli_command_surface.md`
(already captures the contract; this sprint enforces it),
`documents/engineering/code_quality.md` (lint-stack reference is
already in place).

### Objective

Make the operator vocabulary contract structurally enforceable. The
May 21, 2026 Sprint `4.10`–`4.13` code frameworks leaked
"Sprint 4.X" labels into operator-facing CLI help text, manpages,
shell completions, and the generated CLI command reference. This
sprint rewrites every leak site to operator vocabulary and adds the
`prodbox check-code` regex scan that prevents the regression.

### Deliverables

- Every sprint-tagged string in `src/Prodbox/CLI/Spec.hs` rewritten
  to operator vocabulary. The behavioral prose (what `--cascade`
  does, what `--allow-pulumi-residue` bypasses, etc.) is preserved;
  only the sprint identifiers are removed.
- `runNativeDeleteCascade`'s runtime `writeOutputLine` calls
  rewritten similarly. The K8s drain narration still names the
  drain targets (`LoadBalancer Services, Ingresses, Delete-reclaim
  PVCs`) but does not name Sprint 4.11/4.12.
- `src/Prodbox/CheckCode.hs` gains a `checkOperatorVocabulary`
  scan that fails on `Sprint [0-9]` or `Sprints [0-9]` in any file
  under `src/Prodbox/CLI/Spec.hs` (string literals only — comments
  are exempt), `share/man/`, `share/completion/`,
  `documents/cli/`, or `test/golden/cli/`.
- Generated CLI artifacts regenerated via `prodbox docs generate`;
  test goldens refreshed via `cabal test --accept` on
  `command tree` / `command registry JSON` / `leaf help page`.

### Validation

1. `prodbox check-code` exit 0 (with the new scan wired).
2. `prodbox test unit` passes (no new tests strictly required, but
   one regression-guard test invoking the new scan against a
   fixture string `"Sprint 4.99: ..."` and asserting refusal is
   recommended).
3. `grep -rE 'Sprint [0-9]' documents/cli/ share/man/ share/completion/ test/golden/cli/`
   returns nothing.
4. `./.build/prodbox rke2 delete --help`,
   `./.build/prodbox pulumi aws-ses-migrate-backend --help`, and
   `./.build/prodbox nuke --help` outputs contain no `Sprint`
   substring.

### Remaining Work

None. Sprint closed on its owned surface:
`prodbox check-code` exits 0, the new
`checkOperatorVocabulary` scan refuses any `Sprint <digit>` or
`Sprints <digit>` token pair in `src/Prodbox/CLI/Spec.hs` string
literals and in every file under `share/man/`,
`share/completion/`, `documents/cli/`, and `test/golden/cli/`.
`prodbox test unit` runs 410/410 (up from 403 with seven new pure
tests covering `matchesSprintToken` and `extractStringLiterals`).
`grep -rE 'Sprint [0-9]' documents/cli/ share/man/ share/completion/
test/golden/cli/` returns nothing. The leaks at Spec.hs lines 672,
683, 1277, 1327, 1333, 1345, 1438 + Rke2.hs's cascade narration
are rewritten to operator vocabulary; the existing behavioral prose
is preserved.

## Sprint 4.15: Cascade Tolerates Absent Cluster ✅

**Status**: Done (May 21, 2026)
**Blocked by**: Sprint `4.12` (provides the existing `K8sDrain`
module and `runNativeDeleteCascade` wiring this sprint extends).
**Implementation**: `src/Prodbox/Lifecycle/K8sDrain.hs` (add
`DrainSkipped String` constructor to `DrainResult`; add
`clusterReachable :: K8sDrainEnv -> IO Bool` probing
`kubectl cluster-info --request-timeout=5s`, classifying any
non-zero exit or subprocess `Failure` as unreachable without
parsing stderr; gate `drainAwsAffectingK8sResources` on the probe
so `DrainSkipped "Kubernetes API server not reachable; nothing to
drain."` fires before any delete attempt);
`src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` (prepend
`KUBECONFIG=/etc/rancher/rke2/rke2.yaml` to the drain env when
the file exists, using the existing `rke2KubeconfigPath`
constant at line 179; extend the `DrainResult` case-of with a
`DrainSkipped reason -> writeOutputLine ("K8s drain skipped: " ++ reason) >> runNativeDelete repoRoot`
arm; add an inline comment naming the skip-is-success invariant
per
[lifecycle_reconciliation_doctrine.md § 3 layer 1](../documents/engineering/lifecycle_reconciliation_doctrine.md#3-the-reconciler-with-predicates-pattern)).
**Docs to update**:
`documents/engineering/lifecycle_reconciliation_doctrine.md`
(already captures the `DrainResult` outcome ADT and the
skip-is-success invariant; this sprint implements it).

### Objective

Close the symptom surfaced by the May 21, 2026 live run on a host
without a cluster: `prodbox rke2 delete --cascade --yes` failed
noisily because the drain phase called `kubectl delete services
--all-namespaces ...` immediately, `kubectl` fell back to
`localhost:8080` (no `KUBECONFIG`, no
`/etc/rancher/rke2/rke2.yaml`), and the drain returned
`DrainFailed` with memcache connection-refused noise. Operators
running cascade against an already-gone cluster (partial
teardown, first-time provisioning, repeated reruns) should see
`K8s drain skipped: Kubernetes API server not reachable; nothing
to drain.` and proceed to the rest of the cascade.

### Deliverables

- New `DrainSkipped String` constructor on the `DrainResult` ADT.
- New `clusterReachable` helper using the canonical reachability
  probe `kubectl cluster-info --request-timeout=5s`.
- `drainAwsAffectingK8sResources` checks reachability first and
  short-circuits on `DrainSkipped`.
- `runNativeDeleteCascade` sets `KUBECONFIG` from
  `rke2KubeconfigPath` when the file exists, and handles
  `DrainSkipped` as success-with-reason.
- Inline comment in `runNativeDeleteCascade` naming the
  skip-is-success invariant.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` passes (one new pure unit test verifying
   that `DrainSkipped` is treated as a non-failure by the cascade's
   case-of, ideally by refactoring the case-of into a pure helper
   `cascadeDecisionFromDrainResult :: DrainResult -> CascadeDecision`
   and testing the decision matrix).
3. `./.build/prodbox rke2 delete --cascade --yes` on a host without
   a running cluster emits `K8s drain skipped: Kubernetes API
   server not reachable; nothing to drain.` and proceeds to the
   existing `runNativeDelete` sequence (per-run Pulumi destroys +
   manual-cleanup fallback), exiting 0 (or with the existing
   per-run-Pulumi error code if any).
4. `./.build/prodbox rke2 delete --cascade --yes` on a host with a
   running cluster runs the drain normally (no behavior regression
   on the happy path).

### Remaining Work

None. Sprint closed on May 21, 2026 with the absent-cluster path
verified end-to-end via `./.build/prodbox rke2 delete --cascade
--yes` on this host (no rke2 service installed):

```text
Running K8s drain phase (LoadBalancer Services, Ingresses, Delete-reclaim PVCs)...
K8s drain skipped: Kubernetes API server not reachable; nothing to drain. Proceeding with per-run Pulumi destroys + cluster uninstall.
Deleting local RKE2 environment...
AWS EKS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy
AWS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy
Local RKE2 substrate: cleanup complete
Managed kubeconfig: already absent
Preserved host state:
  - manual PV root: /home/matthewnowak/prodbox/.data
  - retained chart state root: /home/matthewnowak/prodbox/.prodbox-state
```

The cascade exit code is 0; the previous "kubectl connection refused"
memcache noise from the May 21 first run is gone. Live cascade
exercise against a host **with** a running cluster rolls up into
Sprint `4.12`'s live closure when that happy-path also runs against
real AWS substrate work.

## Sprint 4.16: ResidueStatus ADT Replaces File-Existence Predicates ✅

**Status**: Done on the code-owned surface. Source-of-truth swap landed 2026-05-27.

Typed ADT, per-stack adapter, caller migration, and the supporting `Prodbox.Infra.StackOutputs` foundation landed earlier (May 23, 2026). The closing change (2026-05-27) introduces `Prodbox.Lifecycle.LiveResidue`, swaps each `<stack>ResidueStatus` to query the actual Pulumi backend, splits `Prodbox.Aws.checkPulumiResidueBeforeTeardown` into a pure `categorizePulumiResidue :: PerRunResidueStatuses -> ResidueStatus -> [(String, String)]` plus an IO wrapper that batches one MinIO port-forward and one S3 query, and refactors the three downstream callers (`Aws.checkPulumiResidueBeforeTeardown`, `Preconditions.noLive{PerRun,LongLived}PulumiStacks`, `Rke2.runNativeDeleteCascade`) onto the batch.

The four `<stack>HasLiveResources :: FilePath -> IO Bool` boolean predicates are removed; per-stack `<stack>ResidueStatus` functions delegate to `LiveResidue` (the per-run trio shares one MinIO port-forward bracket).

A test-only env var `PRODBOX_TEST_RESIDUE_ABSENT=1` (documented at the test-fixture boundary, set by `fakeAwsEnvironment` / `fakeAwsHarnessEnvironment` in `test/integration/CliSuite.hs`) short-circuits both `queryPerRunResidueStatuses` and `queryAwsSesResidueStatus` to `ResidueAbsent` so the fake-AWS-CLI integration suite does not require a running MinIO or a configured long-lived S3 backend. The pure `categorizePulumiResidue` half is the actual subject of the unit-test rewrite; 17 file-existence unit tests are reauthored to inject synthetic `PerRunResidueStatuses` directly, and 13 new tests cover the LiveResidue pure helpers (`residueStatusFromListing`, error-mapping discriminators, suffix-aware stack-name matching) and the per-lifecycle-class doctrine asymmetry (per-run unreachable → absent; long-lived unreachable → still-present).

Removal of `save<Stack>StackSnapshot` / `load<Stack>StackSnapshot` / `clear<Stack>StackSnapshot` and the `AwsXxxStackSnapshot` file-IO surface (the in-memory records stay) remain Sprint 4.18 work. The live AWS-substrate regression (`prodbox test all --substrate aws` produces zero `.prodbox-state/aws-*/` snapshot writes during cascade refusal paths) remains the residual operator-driven closure gate.

**Implementation**: new `src/Prodbox/Lifecycle/LiveResidue.hs` (PerRunResidueStatuses + `queryPerRunResidueStatuses` / `queryAwsSesResidueStatus` IO surface + pure helpers); per-stack `<stack>ResidueStatus` in `src/Prodbox/Infra/{AwsEksTestStack,AwsEksSubzoneStack,AwsTestStack,AwsSesStack}.hs` now delegates to LiveResidue (boolean `<stack>HasLiveResources` predicates removed); `src/Prodbox/Aws.hs` exports the pure `categorizePulumiResidue` alongside the IO wrapper `checkPulumiResidueBeforeTeardown`; `src/Prodbox/Lifecycle/Preconditions.hs` and `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` use the batch query; new test-only env var bound at `src/Prodbox/Lifecycle/LiveResidue.hs::testResidueAbsentEnvVar`; integration helpers `fakeAwsEnvironment` / `fakeAwsHarnessEnvironment` set the var; 17 unit tests rewritten in `test/unit/Main.hs::"Sprint 7.6 AWS harness orphan-safety (Sprint 4.16 source-of-truth pure layer)"` / `"Sprint 7.7 applyAwsTeardown residue policy"` / `"Sprint 7.7 DestroyPulumiResidueFirst dispatch plan"`; 13 new tests in `"Sprint 4.16 LiveResidue error mapping + listing translation"`.

**Validation (2026-05-27)**: `prodbox check-code` exit 0; `prodbox test unit` 567/567 (up from 554); `prodbox test integration cli` 28/28; `prodbox test integration env` 28/28; `prodbox-daemon-lifecycle` 14/14.

**Docs to update**: ✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, ✅ `DEVELOPMENT_PLAN/README.md`, ✅ `DEVELOPMENT_PLAN/system-components.md`, ⏳ `documents/engineering/lifecycle_reconciliation_doctrine.md` (file-existence reference to be updated in a follow-on doc pass), ⏳ `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md` (Sprint 7.6 prose still mentions `<stack>HasLiveResources`).

### Objective

Replace the file-existence predicate
(`<stack>HasLiveResources :: FilePath -> IO Bool` = `doesFileExist` on
`.prodbox-state/<stack>/stack-snapshot.json`) with source-of-truth `ResidueStatus`
queries against the actual Pulumi backend (MinIO for per-run, S3 for long-lived).
The May 22, 2026 cascade-credentials failure on this host exposed the predicate as
the doctrine-violating piece that enables stale-state refusals. See
[lifecycle_reconciliation_doctrine.md §3](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Deliverables

- New `Prodbox.Lifecycle.ResidueStatus` module:
  `data ResidueStatus = ResidueAbsent | ResiduePresent ResidueDetails | ResidueUnreachable ResidueUnreachableReason`.
  Pure ADT with deriving `Eq`, `Show`, and structured-render helpers.
- `<stack>ResidueStatus :: ... -> IO ResidueStatus` per stack in each of
  `src/Prodbox/Infra/AwsEksTestStack.hs`, `AwsEksSubzoneStack.hs`, `AwsTestStack.hs`,
  `AwsSesStack.hs`. Per-run implementations open the MinIO port-forward + login +
  `pulumi stack ls --json` to check for stack presence; long-lived
  (`aws-ses`) implementation queries the S3 backend.
- Removal of `save<Stack>StackSnapshot`, `load<Stack>StackSnapshot`,
  `clear<Stack>StackSnapshot`, `<stack>StateDir`, `<stack>SnapshotPath`, and the
  `AwsXxxStackSnapshot` records' file-IO surface. Output cache replaced by
  `Prodbox.Infra.StackOutputs.fetch :: StackName -> IO (Map Text Text)` which
  shells out to `pulumi stack output --show-secrets` on demand and decodes the
  result.
- Caller updates: `aws teardown` residue policy
  (`src/Prodbox/Aws.hs::checkPulumiResidueBeforeTeardown`,
  `partitionResidueByLifecycle`), `rke2 delete` cascade
  (`src/Prodbox/CLI/Rke2.hs::runNativeDelete{,Cascade}`), harness postflight
  (`src/Prodbox/TestRunner.hs::runWithAwsHarnessCleanup`,
  `src/Prodbox/Aws.hs::runAwsIamHarnessSetup`/`Teardown`). All four switch from
  file-existence to `ResidueStatus`. Per-run `ResidueUnreachable` is treated as
  absent; long-lived `ResidueUnreachable` is a refusal.
- 15+ unit tests in `test/unit/Main.hs::"Sprint 4.16 ResidueStatus"` covering the
  three constructors per stack. 4 cascade-flow tests covering MinIO-up-and-stack-
  present, MinIO-up-and-stack-absent, MinIO-down-per-run (graceful), MinIO-down-
  long-lived (refusal).

### Validation

1. `prodbox check-code` exit 0 (May 23, 2026, code-framework landing; re-confirmed after
   the `Prodbox.Infra.StackOutputs` foundation landed in the later May 23 session).
2. `prodbox test unit` 515/515 (12 ResidueStatus tests + 18 StackOutputs tests; up from
   468 pre-Sprint, then 497 after the first 4.16 landing, then 515 after the
   `StackOutputs` foundation).
3. `prodbox test integration cli` 28/28 (the migrated callers preserve
   refuse-path semantics because the file-existence adapter still drives
   `<stack>ResidueStatus` today).
4. **Live regression (deferred)**: a full `prodbox test all --substrate aws`
   cycle on this host produces zero `.prodbox-state/aws-*/` files at any point
   during the run. This closure gate lands with the source-of-truth swap below.

### Remaining Work

- **Code-owned surface complete (2026-05-27)**. All Sprint 4.16 deliverables
  landed: typed ADT, `StackOutputs` foundation, `LiveResidue` source-of-truth
  module, per-stack adapter delegation, batch-aware caller refactor, and
  the unit-test rewrite to a pure-categorization layer.
- **Snapshot file-IO removal**: `save<Stack>StackSnapshot` /
  `load<Stack>StackSnapshot` / `clear<Stack>StackSnapshot` plus the
  consumers inside `src/Prodbox/TestValidation.hs:~1860–1920` (three
  `load*StackSnapshot` call sites) are Sprint 4.18 scope.
- **Live AWS-substrate gate**: `prodbox test all --substrate aws`
  produces zero `.prodbox-state/aws-*/` snapshot writes during cascade
  refusal paths. Tracked as the operator-driven closure gate alongside
  the broader Sprint 7.5.c.v live re-run.

## Sprint 4.17: Cascade Canonical Order and Self-Materialize Operational Creds 🔄

**Status**: Active on the live operator step only; every code-owned half landed May 23, 2026. (a) Credential-fallback half (May 23, 2026 a.m.) — each per-run `loadOperationalAwsCredentials` (in `AwsEksTestStack`, `AwsTestStack`, and transitively `AwsEksSubzoneStack` via re-import) falls back to `aws_admin_for_test_simulation.*` when operational `aws.*` is empty. (b) Cascade-order rewrite (May 23, 2026 p.m.) reorders `runNativeDeleteCascade` to the canonical sequence (confirm-MinIO via per-stack `<stack>ResidueStatus` → per-run Pulumi destroys for any `ResiduePresent` stack → K8s drain → RKE2 uninstall + cluster-substrate cleanup → postflight cluster-tag sweep) per [lifecycle_reconciliation_doctrine.md §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md). (c) **Postflight tag sweep wiring (May 23, 2026 later session)** — `runCascadePostflightTagSweep` now loads admin credentials via `Prodbox.Infra.LongLivedPulumiBackend.loadAdminAwsCredentials`, builds the AWS env via `Prodbox.Aws.adminAwsEnvironment`, and calls `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` with `tagSweepClusterName = Just awsEksCanonicalClusterName`; an empty result is reported as "clean (no cluster-tagged or prodbox-owned AWS residue)" and a non-empty result is reported with the full `renderTagSweepRefusal` block, while the cascade still returns `ExitSuccess` (best-effort per doctrine §6). When admin credentials are not configured (home-only operator with no AWS substrate), the sweep emits a single-line skip diagnostic explaining that no AWS resources could exist. 4 new unit tests in `test/unit/Main.hs::"Sprint 4.17 postflight tag sweep wiring"` cover the refusal-block ARN/tag rendering, the multi-resource bullet output, the empty-list path, and the `TagSweepInput` record shape. The remaining live operator validation closes the sprint: a real cascade run on this host (or a substrate-equivalent) that exercises the new order end-to-end against a live cluster with at least one per-run Pulumi stack alive.
**Blocked by**: live operator step only (real cascade against a host with a live `aws-eks` stack); every code-owned deliverable is shipped.
**Implementation**: `src/Prodbox/Infra/AwsEksTestStack.hs::loadOperationalAwsCredentials` and `src/Prodbox/Infra/AwsTestStack.hs::loadOperationalAwsCredentials` (May 23, 2026 a.m., in-memory operational→admin fallback). `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` (May 23, 2026 p.m., reordered to confirm-MinIO → per-run destroys → drain → uninstall → postflight sweep); new helpers `perRunCascadeInventory` (pure, exported, drives test coverage), `runCascadeDrainPhase`, `runCascadePostflightTagSweep`; cascade now consumes the typed `<stack>ResidueStatus` adapter from Sprint 4.16 and skips per-run destroys whose stack reports `ResidueAbsent` (or `ResidueUnreachable` per the per-run lifecycle class). 7 new unit tests in `test/unit/Main.hs::"Sprint 4.17 cascade per-run inventory"` cover all-absent / all-present / individual-stack-present / `ResidueUnreachable`-treated-as-absent permutations. **Tag sweep wiring (May 23, 2026 later session)**: `runCascadePostflightTagSweep` rewritten in `src/Prodbox/CLI/Rke2.hs` to invoke `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` against the admin AWS environment when `aws_admin_for_test_simulation.*` is configured; new exports `awsEksCanonicalClusterName` on `Prodbox.Infra.AwsEksTestStack` so the cascade can build the canonical `kubernetes.io/cluster/<name>` filter; 4 new unit tests in `"Sprint 4.17 postflight tag sweep wiring"` lift `renderTagSweepRefusal` + `TagSweepInput` invariants out of the live-only path (test count 519/519, up from 515).
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`

### Objective

Reorder `prodbox rke2 delete --cascade` to release MinIO-tracked AWS resources
before the local cluster is uninstalled, and eliminate the cascade-credentials
failure class by generalizing the Sprint 7.7 `aws-ses` self-materialize bracket to
all per-run stacks. See
[lifecycle_reconciliation_doctrine.md §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md)
for the authoritative cascade-order table.

### Deliverables

- **Credential-fallback half (Done May 23, 2026)**: each per-run
  `loadOperationalAwsCredentials` (in
  `src/Prodbox/Infra/AwsEksTestStack.hs` and
  `src/Prodbox/Infra/AwsTestStack.hs`) tries operational `aws.*` first and
  transparently falls back to `aws_admin_for_test_simulation.*` when
  operational is empty. `src/Prodbox/Infra/AwsEksSubzoneStack.hs` inherits
  the new behavior because it re-imports `loadOperationalAwsCredentials`
  from `AwsEksTestStack`. No file mutation: the destroy paths only *read*
  credentials, so the in-memory fallback is sufficient. 4 new unit tests
  in `test/unit/Main.hs::"Sprint 4.17 destroy-path credential fallback"`
  cover the `credentialsConfigured` smart-constructor semantics that drive
  the fallback branch.
- **Cascade-order rewrite (landed wrong order May 23, 2026 p.m.; correction scheduled as Sprint 4.17.a)**:
  `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` initially shipped with the
  order:
  1. Confirm MinIO reachable via per-stack `<stack>ResidueStatus` queries
  2. Per-run `pulumi destroy` for stacks reporting `ResiduePresent`
  3. K8s drain (Sprint 4.12)
  4. RKE2 uninstall + cluster-substrate cleanup
  5. Postflight cluster-tag sweep

  The May 27/28 AWS-substrate live exercise on Bathurst surfaced this as
  the wrong order: on the AWS substrate the per-run destroys (step 2) run
  while AWS Load Balancer Controller + EBS CSI driver are still alive on
  the EKS cluster, leaving orphan ENIs that block subnet deletion
  (`DependencyViolation: The subnet '<id>' has dependencies and cannot be
  deleted`). The doctrine-canonical order — drain BEFORE per-run destroys
  — is documented in
  [`lifecycle_reconciliation_doctrine.md` §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  and tracked as new Sprint 4.17.a below. The pure helper
  `perRunCascadeInventory` (exported) drives unit test coverage of the
  canonical destroy ordering; the existing helpers `runCascadeDrainPhase`
  / `runCascadePostflightTagSweep` are preserved as named phases. Sprint
  4.17.b adds substrate-aware kubeconfig handling to the drain phase.
- **Optional ergonomic bracket (Remaining)**: an explicit
  `Prodbox.Aws.withMaterializedOperationalCreds :: IO a -> IO a` that
  *mutates* `aws.*` in `prodbox-config.dhall` for the body and restores
  on exit. Only required if a future call site needs the mutating
  semantics (today's in-memory fallback satisfies every destroy-path
  reader). Lands when the postflight tag sweep grows admin-credentials
  wiring.

### Validation

1. `prodbox check-code` exit 0 (May 23, 2026 p.m., after cascade
   reorder; re-confirmed after the postflight-tag-sweep wiring landed
   in the later May 23 session).
2. `prodbox lint docs` exit 0; `prodbox docs check` exit 0.
3. `prodbox test unit` 519/519 (7 cascade-inventory + 12 Residue + 18
   StackOutputs + 4 postflight-tag-sweep wiring tests; up from 468 at
   sprint start).
4. `prodbox test integration cli` 28/28 (cascade refactor preserves the
   existing rke2 reconcile + delete integration cases).
5. **Live regression (deferred to operator)**: bring up `aws-eks` via
   `prodbox test integration aws-iam --substrate aws`; manually clear
   `aws.*` in `prodbox-config.dhall`; run `prodbox rke2 delete --cascade
   --yes`; confirm it succeeds with output ordering
   "confirm-MinIO → per-run destroys → drain → uninstall → sweep" and
   without the May 22 error message ("operational AWS credentials are
   required to destroy the AWS EKS test stack once a Pulumi stack
   exists: aws.access_key_id must not be empty") because the load helper
   now falls back.

### Remaining Work

All code-owned work is shipped. The postflight tag sweep now invokes
`Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` against
the admin AWS environment when `aws_admin_for_test_simulation.*` is
populated; the explicit `Prodbox.Aws.withMaterializedOperationalCreds`
bracket remains an optional ergonomic future addition only if a call
site needs the file-mutating semantics (today's in-memory fallback
satisfies every destroy-path reader, and the postflight is a
read-only AWS Resource Tagging API query). The remaining closure is
the live operator step: bring up `aws-eks` via
`prodbox test integration aws-iam --substrate aws`, then run
`prodbox rke2 delete --cascade --yes` and confirm the cascade ordering
matches the canonical sequence and the postflight reports either
"clean" or a structured refusal block. The final cleanup (kubeconfig
on-demand, SSH key via Pulumi output, tmp tarball, `forbidDotProdboxState`
lint) is Sprint 4.18. The cascade-order correction + substrate-aware
drain land via Sprints 4.17.a and 4.17.b below.

## Sprint 4.17.a: Reorder Cascade to Doctrine-Canonical Sequence ✅

**Status**: Done (May 28, 2026 on the code-owned surface; AWS-substrate
live re-verification rolls up with Sprint 4.17.b)
**Implementation**: `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade`
+ new top-level constant `cascadeOrderNarration` exposed as a stable
test pin; pure helper `perRunCascadeInventory` unchanged.
**Blocked by**: none (independent of 4.17.b on the home substrate; AWS
substrate verification needs both)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`
(updated May 28, 2026 to flip §5b table + §1 prose);
`documents/engineering/cli_command_surface.md` (updated May 28, 2026
`prodbox rke2 delete --cascade` section);
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
(legacy row moved Pending → Completed)

### Objective

Reorder cascade phases to match the doctrine-canonical sequence
`confirm-MinIO → drain → per-run destroys → uninstall → sweep` so AWS-side
controllers (AWS Load Balancer Controller, EBS CSI driver) unwind their
ENIs / ALBs / EBS volumes before the per-run Pulumi destroy phase tries
to delete the substrate. The pre-correction order
(`destroys → drain`) was harmless on the home substrate (no
in-cluster AWS controllers) but fatal on the AWS substrate, producing
`DependencyViolation: The subnet '<id>' has dependencies and cannot
be deleted` errors mid-destroy with no recoverable path.

### Deliverables

- Reorder the orchestration block at
  `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` (lines 748–806) to
  match the doctrine §5b table. The pure helper `perRunCascadeInventory`
  does not move; only the orchestration sequence around it changes.
- Update the docstring at lines 722–730 to remove the "trade-off"
  rationale that justified the wrong order. Replace with the
  substrate-aware rationale from
  [`lifecycle_reconciliation_doctrine.md` §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md).
- Add a Sprint 4.17.a regression test in `test/unit/Main.hs` pinning the
  canonical phase order against `perRunCascadeInventory` outputs (the
  test renders the cascade plan and asserts `drain` appears before
  `per-run destroys`).

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` passes (with the new phase-order test).
3. `prodbox test integration cli` 28/28 (cascade refactor preserves the
   existing `rke2 reconcile + delete` integration cases).
4. Live re-verification on the home substrate: `prodbox rke2 reconcile`,
   deploy charts, then `prodbox rke2 delete --cascade --yes` — confirm
   the cascade narration emits `drain` before `per-run destroys`.
5. Live re-verification on the AWS substrate is the gate for Sprint
   4.17.b (a full `prodbox test all --substrate aws` cycle completes
   cleanly only when both 4.17.a and 4.17.b are landed).

### Remaining Work

Code-owned work landed May 28, 2026: 5 new unit tests pin the canonical
phase order via the `cascadeOrderNarration` constant
(`test/unit/Main.hs::"Sprint 4.17.a canonical cascade phase order"`).
Live re-verification on the home substrate (`prodbox rke2 reconcile`,
deploy charts, then `prodbox rke2 delete --cascade --yes` — confirm
narration emits `drain` before `per-run destroys`) and on the AWS
substrate (full `prodbox test all --substrate aws` cycle completes
cleanly) are the only remaining closure gates. The AWS-substrate gate
rolls up with Sprint 4.17.b.

## Sprint 4.17.b: Substrate-Aware K8s Drain Phase ✅

**Status**: Done (May 28, 2026 on the code-owned surface; live
AWS-substrate verification remains the operator-driven gate)
**Implementation**: `src/Prodbox/CLI/Rke2.hs::runCascadeDrainPhase`
+ new pure helper `inferCascadeSubstrate` (exported for unit tests)
+ new helper `buildDrainEnvironment` building the substrate-aware
env-var list; `src/Prodbox/Lifecycle/K8sDrain.hs` unchanged
(`drainAwsAffectingK8sResources` consumes the env list the cascade
phase now constructs per-substrate).
**Blocked by**: Sprint 4.17.a (the substrate-aware drain only matters
when drain runs in the canonical position before per-run destroys)
**Docs to update**:
`documents/engineering/lifecycle_reconciliation_doctrine.md §5b`
(updated May 28, 2026 to require substrate-aware drain),
`documents/engineering/aws_integration_environment_doctrine.md §5.5`
(added May 28, 2026),
`DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` (legacy row moved
Pending → Completed)

### Objective

`runCascadeDrainPhase` currently hard-codes
`KUBECONFIG=/etc/rancher/rke2/rke2.yaml` — the local RKE2 cluster's
kubeconfig. On the AWS substrate this means the drain phase walks the
local cluster's namespaces (which have no AWS LoadBalancer Services)
and reports nothing to drain. The EKS-side LoadBalancer Services / ALB
Ingresses / Delete-reclaim PVCs are never deleted before per-run
destroys begin, so the AWS LBC + EBS CSI controllers keep their ENIs
alive into the subnet-deletion phase.

Take a `Substrate` argument and use
`Prodbox.PublicEdge.withSubstrateKubectlEnvironment` (already exported
from `src/Prodbox/PublicEdge.hs`) for `SubstrateAws` so the drain phase
talks to the EKS API and actually removes the resources holding ENIs.
For `SubstrateHomeLocal` keep the existing local-kubeconfig behaviour.

### Deliverables

- Change `runCascadeDrainPhase` signature to take `Substrate`.
- Wrap `K8sDrain.drainAwsAffectingK8sResources` in
  `withSubstrateKubectlEnvironment` so kubectl + `aws eks get-token`
  receive the substrate's `KUBECONFIG` + `AWS_*` env.
- The cascade call site at
  `runNativeDeleteCascade` passes through the per-stack substrate
  already in scope.
- Treat `DrainSkipped` on the AWS substrate as a hard failure (the EKS
  cluster is the source of the resources that the per-run destroys will
  fail to delete; skipping the drain guarantees the failure). On the
  home substrate `DrainSkipped` remains success-with-reason per Sprint
  4.15.
- Add a unit test that asserts `runCascadeDrainPhase SubstrateAws` sets
  the EKS kubeconfig path via the bracket.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` passes (with the new kubeconfig-selection test).
3. `prodbox test integration cli` 28/28.
4. **Live AWS-substrate re-verification**: a full
   `prodbox test all --substrate aws` cycle (or alternatively
   provisioning aws-eks then running `prodbox rke2 delete --cascade
   --yes`) completes cleanly. The cascade narration emits
   `drain (substrate=aws)` followed by `per-run destroys`, and the
   destroys succeed without `DependencyViolation` on subnet deletion.

### Remaining Work

Code-owned work landed May 28, 2026: `runCascadeDrainPhase` now takes
`Substrate`; for `SubstrateAws` it builds `KUBECONFIG=<aws-eks-test
kubeconfig>` + `AWS_*` from `settings.aws`; for `SubstrateHomeLocal` it
keeps the existing local-kubeconfig path. `DrainSkipped` on
`SubstrateAws` is now a hard failure with an explanatory message
naming `DependencyViolation` as the downstream symptom. The cascade
caller infers the substrate from per-run residue via the new pure
helper `inferCascadeSubstrate` (any AWS per-run stack reporting
`ResiduePresent` → `SubstrateAws`; otherwise `SubstrateHomeLocal`). 6
new unit tests in `test/unit/Main.hs::"Sprint 4.17.b cascade substrate
inference"` pin every combination. Live AWS-substrate verification
(full `prodbox test all --substrate aws` cycle completes cleanly
including the cascade) is the closure gate. The
`Prodbox.PublicEdge.withSubstrateKubectlEnvironment` helper is not used
here because `K8sDrain.K8sDrainEnv` takes an explicit env-var list
rather than mutating process env via `setEnv`; the substrate-aware env
construction lives in the new `buildDrainEnvironment` helper instead.

## Sprint 4.18: Remove Remaining .prodbox-state Artifacts and Final Lint 🔄

**Status**: Active. First chunk of code-owned work landed 2026-05-27 on
top of Sprint 4.16's source-of-truth swap:

- Tarball scratch directories moved from
  `repoRoot </> ".prodbox-state" </> "tmp"` to the system temporary
  directory in `src/Prodbox/Lib/AwsSubstratePlatform.hs::withTempJsonFile`
  and `src/Prodbox/CLI/Rke2.hs::pushCustomImageVariantsViaInClusterCrane`.
- New `Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs` /
  `fetchAwsSesStackOutputs` foundation reads stack outputs from the
  live Pulumi backend (MinIO for per-run, S3 for long-lived) via the
  existing `Prodbox.Infra.StackOutputs.fetchOutputs` surface.
- Two consumers migrated off `loadXxxStackSnapshot` to the live read:
  `src/Prodbox/PublicEdge.hs::resolveSubstrateHostedZoneId` (reads
  `subzone_id` from `aws-eks-subzone` outputs) and
  `src/Prodbox/TestValidation.hs::verifyAwsEksSnapshot` (reads
  `cluster_name` + `subnet_ids` from `aws-eks-test` outputs).

Second chunk landed 2026-05-27 (later session):

- New pure parsers `Prodbox.Infra.AwsTestStack.parseAwsTestNodesFromOutputs`
  and `Prodbox.Infra.AwsEksTestStack.parseAwsEksTestStackFromOutputs`
  decode the live `Map Text Text` returned by
  `fetchPerRunStackOutputs` into structured `[AwsTestNode]` and
  `AwsEksTestStackSnapshot` records respectively.
- Three additional consumers migrated off `loadXxxStackSnapshot`:
  `src/Prodbox/TestValidation.hs::verifyAwsTestSnapshot`,
  `src/Prodbox/TestValidation.hs::verifyAwsTestSshReachability`
  (sharing a new `fetchAwsTestNodes` helper), and
  `src/Prodbox/Lib/AwsSubstratePlatform.hs::ensureAwsSubstratePlatformRuntime`
  (constructs the in-memory `AwsEksTestStackSnapshot` from live outputs
  instead of `.prodbox-state/aws-eks-test/stack-snapshot.json`).
- `Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs` gains a
  test-only `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` override that reads the
  outputs map from `<dir>/<stack-name>.json` so the unit suite can
  exercise the migrated consumers without a live MinIO port-forward.
- 7 new unit tests pin the two pure parsers' happy paths plus the
  missing-field / non-JSON / wrong-shape failure modes. The
  `native validation helpers` SSH-retry test is rewritten to inject
  the `nodes` output via the new override instead of writing
  `.prodbox-state/aws-test/stack-snapshot.json`.

Validated with `prodbox check-code` exit 0, `prodbox test unit`
574/574 (up from 567), `prodbox test integration cli` 28/28,
`prodbox test integration env` 28/28.

Third chunk landed 2026-05-27 (later session): the two per-run stacks
the home `prodbox test all` exercises (`aws-eks-test`, `aws-test`) drop
their on-disk snapshot cache entirely.

- New `fetchAwsEksTestSnapshotFromBackend` /
  `fetchAwsTestSnapshotFromBackend` (each returning the same `Maybe
  <Snapshot>` the file cache used to) read the stack snapshot live from
  the in-cluster MinIO Pulumi backend via `fetchPerRunStackOutputs` +
  the pure parsers (`parseAwsEksTestStackFromOutputs`, new
  `parseAwsTestStackFromOutputs`). The destroy path fetches the snapshot
  pre-destroy (stack still present), so the precise per-resource residue
  check behaves exactly as before; an absent / unreachable / unparseable
  read falls back to the canonical tag-based residue scan, matching the
  old `Nothing` arm.
- Every internal `loadAwsEksTestStackSnapshot` /
  `loadAwsTestStackSnapshot` consumer migrated to the live read:
  `ensureXxxStackResources` (pre-provision residue check),
  `destroyXxxStackStatus`, and `assertNoXxxStackResidue`.
- All `saveXxxStackSnapshot` / `clearXxxStackSnapshot` callsites removed,
  and the file-IO helpers deleted: `save`/`load`/`clear`,
  `<stack>SnapshotPath`, `snapshotToJson` / `snapshotFromJson` /
  `nodeToJson`, and (for EKS) the now-unused `optionalString`. The
  `<stack>StateDir` helpers survive only because the HA-RKE2 SSH keypair
  and the EKS kubeconfig still live there pending the next chunk.
- The unit round-trip test that exercised `save`/`load` is replaced by
  two `parse*FromOutputs` round-trips over the flat `Map Text Text`
  backend shape (test count 575/575, up from 574).

Static gates green: `prodbox check-code` exit 0, `prodbox test unit`
575/575, `prodbox test integration cli` 28/28, `prodbox test
integration env` 28/28. Live validation (`prodbox test all` on the home
substrate, exercising the `aws-eks` + `ha-rke2-aws` provision/destroy
paths against the migrated code) is the closure gate and is in progress.

**Remaining (code-owned)**:
- Apply the same snapshot-read migration + file-IO removal to the
  `aws-eks-subzone` and `aws-ses` stacks (`destroyAwsEksSubzoneStackStatus`
  / `destroyAwsSesStackStatus` read live outputs via
  `fetchPerRunStackOutputs` / `fetchAwsSesStackOutputs`). Validated by
  the AWS-substrate run (subzone) and an explicit `aws-ses-destroy`
  (long-lived).
- Replace `awsEksTestKubeconfigPath` (currently
  `.prodbox-state/aws-eks-test/kubeconfig`) with a
  `withEksKubeconfig :: ... -> (FilePath -> IO a) -> IO a` bracket
  that `aws eks update-kubeconfig --kubeconfig <mktemp>`'s into a
  scoped temp file. Note: the kubeconfig is currently a cross-invocation
  persistent artifact (written by `pulumi eks-resources`, read by later
  `charts deploy` / validation / `destroy` runs), so the bracket must
  re-derive on demand in every consumer rather than being a one-shot
  scratch file.
- Replace SSH key paths under `.prodbox-state/aws-test/id_ed25519{,.pub}`
  with `mktemp` + `pulumi stack output --show-secrets ssh_private_key`
  (requires a corresponding Pulumi stack change to expose the private
  key as a secret output).
- Add `forbidDotProdboxState` lint rule to `src/Prodbox/CheckCode.hs`
  after the chart-secret cache (`src/Prodbox/Lib/ChartPlatform.hs` +
  `UsersAdmin.hs` + `Keycloak/Admin.hs` + `AwsSesStack.hs` SMTP secrets
  + `TestValidation.hs:1859` chart-secret consumer + the two test-file
  references) closes with Sprint 3.13.

**Blocked by**: Sprint 3.13 (chart-secret cache references must close
before `forbidDotProdboxState` lint can land).

**Implementation**: `src/Prodbox/Lib/AwsSubstratePlatform.hs::withTempJsonFile` (system tmp dir; 2026-05-27); `src/Prodbox/CLI/Rke2.hs::pushCustomImageVariantsViaInClusterCrane` (system tmp dir; 2026-05-27); `src/Prodbox/Lifecycle/LiveResidue.hs` (new `fetchPerRunStackOutputs` + `fetchAwsSesStackOutputs` exports + `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` test override; 2026-05-27); `src/Prodbox/PublicEdge.hs::resolveSubstrateHostedZoneId` (live `subzone_id` read; 2026-05-27); `src/Prodbox/TestValidation.hs::verifyAwsEksSnapshot` (live `cluster_name` + `subnet_ids` read; 2026-05-27); `src/Prodbox/Infra/AwsTestStack.hs::parseAwsTestNodesFromOutputs` (new pure decoder; 2026-05-27 later session); `src/Prodbox/Infra/AwsEksTestStack.hs::parseAwsEksTestStackFromOutputs` (new pure decoder; 2026-05-27 later session); `src/Prodbox/TestValidation.hs::verifyAwsTestSnapshot` + `verifyAwsTestSshReachability` + `fetchAwsTestNodes` (live read; 2026-05-27 later session). Third chunk (2026-05-27 later session): `src/Prodbox/Infra/AwsTestStack.hs::parseAwsTestStackFromOutputs` + `fetchAwsTestSnapshotFromBackend` (full-snapshot live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`nodeToJson`/`awsTestSnapshotPath` removed); `src/Prodbox/Infra/AwsEksTestStack.hs::fetchAwsEksTestSnapshotFromBackend` (live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`optionalString`/`awsEksTestSnapshotPath` removed); `src/Prodbox/Lib/AwsSubstratePlatform.hs::ensureAwsSubstratePlatformRuntime` (live read; 2026-05-27 later session).

**Docs to update**: ✅ `DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`, ⏳ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` (full closure row when remaining work lands).

### Objective

Finish removing every code-side and config-side `.prodbox-state/` reference. After
this sprint, `grep -rn '\.prodbox-state' src/ app/ test/ charts/ pulumi/ documents/
DEVELOPMENT_PLAN/ README.md CLAUDE.md AGENTS.md` returns zero hits.

### Deliverables

- EKS kubeconfig re-derives on demand via a new
  `Prodbox.Infra.EksKubeconfig.withEksKubeconfig` bracket that materializes a
  `mktemp` file by invoking `aws eks update-kubeconfig` and cleans up on exit.
- HA-RKE2 validation SSH key: read from
  `pulumi stack output --show-secrets ssh_private_key` into a `mktemp` file scoped
  to the validation run; old `.prodbox-state/aws-test/id_ed25519{,.pub}` paths
  removed from the source tree.
- Custom-image tarball at
  `/tmp/prodbox-custom-image-<run-id>.tar` instead of
  `.prodbox-state/tmp/prodbox-custom-image.tar`; caller `bracket`s the cleanup.
- New `prodbox lint files` rule `forbidDotProdboxState` in
  `src/Prodbox/CheckCode.hs` refuses any `.prodbox-state/*` write in source.
  Allowlist accepts only the legacy-tracking ledger references and historical
  sprint blocks.
- `.gitignore`, `CLAUDE.md`, and `prodbox.cabal` cleaned of `.prodbox-state/`
  references.
- Final grep gate: `! grep -rn '\.prodbox-state' src/ app/ test/ charts/ pulumi/
  documents/ DEVELOPMENT_PLAN/ README.md CLAUDE.md AGENTS.md` returns zero hits.

### Validation

1. `prodbox check-code` exit 0 (the new lint rule fires on any future
   regression).
2. `prodbox docs check` exit 0.
3. `prodbox test unit` exit 0.
4. `prodbox test integration cli` + `prodbox test integration env` exit 0.
5. Live verification: the four-block end-to-end run from the approved plan Part 3
   exercises every preserved-data + recovery-escape-hatch + original-failure-mode
   path.

### Remaining Work

None on the sprint-owned surface. Part 3 of the approved plan rolls up the end-to-
end verification.

## Sprint 4.19: `rke2 delete` Fails Closed When Per-Run Pulumi State Is Unreachable ✅

**Status**: Done on the code-owned surface (2026-05-28). Live verification via
`prodbox rke2 delete --yes` against an intentionally-unreachable per-run backend
on this host is the residual operator gate.

**Implementation**: `src/Prodbox/Lifecycle/ResidueStatus.hs::isResiduePresentOrUnknownPerRun`
(realigned to its name — now `isResiduePresent s || isResidueUnreachable s`, fail-closed
on unreachable); `src/Prodbox/Lifecycle/Preconditions.hs::noLivePerRunPulumiStacks` (branches
on the `ResidueStatus` constructor; new `perRunSummaryLine` / `renderPerRunRefusal` emit a
distinct, actionable refusal for the unreachable case); `src/Prodbox/Aws.hs::categorizePulumiResidue`
(per-run unreachable now counts as blocking residue for `aws teardown`);
`src/Prodbox/Lifecycle/LiveResidue.hs` (new test-only `PRODBOX_TEST_RESIDUE_UNREACHABLE`
override + `perRunUnreachableTriple`, symmetric to `PRODBOX_TEST_RESIDUE_ABSENT`).

**Docs to update**: ✅ `documents/engineering/lifecycle_reconciliation_doctrine.md` (§3 layer 1
gate-vs-cascade asymmetry; §4 `noLivePerRunPulumiStacks` row), ✅ this file,
✅ `DEVELOPMENT_PLAN/README.md`.

### Objective

`prodbox rke2 delete --yes` must not report a clean per-run AWS teardown when it could not
read the authoritative per-run Pulumi state. Previously the gate treated
`ResidueUnreachable` (in-cluster MinIO state backend unreachable) the same as
`ResidueAbsent` and passed silently. On a degraded cluster (MinIO pod down, per-run state
still intact on `.data/`) the operator then ran the documented `rm .data` "start from
scratch" action on the strength of that false "clean" signal — destroying the only record
of still-live AWS resources and orphaning them permanently. The defect: the gate equated
*unreadable state* with *no resources*.

### Deliverables

- The per-run delete gate (`noLivePerRunPulumiStacks`, used by `prodbox rke2 delete`
  default and `prodbox aws teardown`) **fails closed on `ResidueUnreachable`** with a
  distinct refusal: "cannot read the per-run Pulumi state backend (MinIO) … the per-run
  state may still be intact on `.data/` — do NOT delete `.data/` until it is confirmed
  destroyed … or re-run with `--allow-pulumi-residue` to accept the orphan risk."
- `ResiduePresent` keeps the existing "live resources — destroy first / `--cascade`"
  refusal. `ResidueAbsent` still passes.
- The `--cascade` path is **unchanged**: its own `perRunCascadeInventory` deliberately
  treats per-run unreachable as absent (the cluster is being torn down regardless, with
  the postflight tag sweep as backstop). The deliberate gate-vs-cascade asymmetry is
  documented in `lifecycle_reconciliation_doctrine.md` §3.
- `--allow-pulumi-residue` remains the explicit escape — turning a silent pass into an
  explicit, acknowledged operator decision.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` 578/578 (helper test asserts unreachable → blocking; the
   `categorizePulumiResidue` unreachable-per-run test now expects a refusal list; 3 new
   tests pin the refusal messages).
3. `prodbox test integration cli` 30/30 — two new tests: `rke2 delete --yes` with an
   unreachable per-run backend exits `ExitFailure 1` with the new message and **does not**
   print "Deleting local RKE2 environment…"; `--allow-pulumi-residue` still proceeds.
   `prodbox test integration env` 30/30.
4. Live (residual): `prodbox rke2 delete --yes` on this host with no reachable
   cluster/MinIO refuses loudly instead of reporting clean.

### Remaining Work

Live operator verification on this host (run the 4.19 binary against an unreachable
per-run backend and confirm `rke2 delete --yes` refuses). No remaining code-owned work
on the sprint surface.

### Follow-up: IAM-orphan residual class (2026-05-28)

A read-only AWS sweep after a live `rke2 delete --yes` confirmed the per-run leak was
confined entirely to **IAM** (no orphan EKS/EC2/VPC/ELB/NAT/EBS/OIDC residue): the
`aws-eks-test-aws-lb-controller` policy, three EKS roles (`clusterRole-*`/`nodeRole-*`),
and the operational `prodbox` IAM user, accumulated across runs dated 2026-04-25 →
2026-05-28. These were removed by the bounded operator escape hatch (targeted `aws iam`
deletes) and a re-sweep confirmed only the retained `prodbox-admin-temp`,
`prodbox-ses-smtp`, and the operator-owned Route 53 zone remain. The IAM-orphan class
has **no automated detection backstop** (the AWS Resource Groups Tagging API does not
return IAM), so it is handled by prevention (this sprint's fail-closed gate) plus
operator cleanup — deliberately **not** by an AWS-name-scanning detector or an
auto-sweep. Documented as a residual class in
[substrates.md → Orphaned IAM residue](substrates.md#resource-lifecycle-classes) and
[lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md).

## Sprint 4.20: Managed-Resource Registry Foundation + Soundness ✅

**Status**: Done on the code-owned surface (2026-05-28). Behavior-preserving and
fully static-validatable; no live re-run needed (the registry is not yet wired into a
teardown reconciler — that is Sprint 4.21 — so teardown behavior is unchanged).
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs` (new),
`src/Prodbox/Lifecycle/ResidueStatus.hs` (`residueBlocksTeardownGate`),
`src/Prodbox/Aws.hs` (derived `perRunStackNames`/`longLivedStackNames`; `categorizePulumiResidue`),
`src/Prodbox/Lifecycle/Preconditions.hs` (`noLiveLongLivedPulumiStacks`)
**Docs to update**: ✅ `documents/engineering/lifecycle_reconciliation_doctrine.md` (§3.1, SSoT),
✅ `DEVELOPMENT_PLAN/substrates.md`, ✅ `DEVELOPMENT_PLAN/system-components.md`,
✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Introduce the single source of truth for "everything prodbox can create, and how to observe
and destroy it" — the typed managed-resource registry that the
[reconciler-with-predicates doctrine § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
prescribes. This generalizes the per-stack residue model (Sprint 4.16), the predicate library
(Sprint 4.11), and the fail-closed gate (Sprint 4.19) into one pattern; those sprints stay
`Done` and become instances of it.

### Deliverables (landed)

- New low-level `Prodbox.Lifecycle.ResourceClass` — `LifecycleClass (PerRun | LongLived |
  Operational)` plus the pure SSoT facts `resourceLifecycleClasses :: [(String, LifecycleClass)]`
  (the per-run stacks, `aws-ses`, and the two registered operational resources) and
  `resourceNamesOfClass`. Kept dependency-light so it sits below `Prodbox.Aws` /
  `Prodbox.Lifecycle.LiveResidue` without an import cycle.
- `Prodbox.Aws.perRunStackNames` / `longLivedStackNames` are **derived** from the facts by
  class (no hand-maintained literals; a unit test asserts they equal the prior literals).
- A single `Unreachable`-never-passes soundness combinator
  `Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate` (present OR unreachable → block),
  superseding the per-class `isResiduePresentOrUnknown{PerRun,LongLived}` booleans (removed).
  `categorizePulumiResidue` and `noLiveLongLivedPulumiStacks` now use it; the cascade keeps its
  documented graceful-degradation exception.

### Boundary refinement vs. the original plan

The IO-bearing `ManagedResource { resourceDiscover, resourceDestroy }` record and the
`managedResources` registry move to **Sprint 4.21**, where `reconcileAbsent` is their first
consumer — building discover/destroy closures that nothing calls yet would be dead code, and a
naive per-resource discover would regress the per-run port-forward batching that
`queryPerRunResidueStatuses` already does. Sprint 4.20 lands the pure facts + derived lists +
the soundness combinator (the load-bearing, behavior-preserving foundation); 4.21 decorates the
facts with batched discover/destroy and the reconciler. The operational resources are
**registered as class facts** here; their discover/destroy wiring lands with 4.21/7.8.

### Validation

`prodbox check-code` exit 0; `prodbox test unit` 583/583 (6 new registry-facts tests incl.
derived-lists-equal-prior-literals + the `residueBlocksTeardownGate` Present/Absent/Unreachable
table); `prodbox test integration cli` 30/30; `prodbox test integration env` 30/30.

### Remaining Work

None on the sprint-owned surface. The IO registry + reconciler land in Sprint 4.21.

## Sprint 4.21: IO Managed-Resource Registry + `reconcileAbsent` (cascade per-run) ✅

**Status**: Done on the code-owned surface (2026-05-28). Behavior-preserving refactor of the
cascade per-run destroy phase; live cascade smoke passed on this host. The present→destroy
path's full live exercise rolls up with the next AWS-substrate cascade run (operator-driven).
**Implementation**: `src/Prodbox/Lifecycle/ResourceRegistry.hs` (new — `ManagedResource`,
`perRunManagedResources`, `pairPerRunResidue`, `resourcesToDestroy`, `reconcileAbsent`),
`src/Prodbox/CLI/Rke2.hs` (`runNativeDeleteCascade` per-run phase routed through the registry;
`perRunCascadeInventory` removed)
**Docs to update**: ✅ `documents/engineering/lifecycle_reconciliation_doctrine.md` (§3.1),
✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Land the IO-bearing managed-resource registry and the `reconcileAbsent` teardown reconciler
(§3.1), and route the cascade's per-run destroy phase through them — unifying the per-run
destroy commands into the registry SSoT so 4.22 / 7.8 / nuke can reuse them.

### Deliverables (landed)

- New `Prodbox.Lifecycle.ResourceRegistry`: the IO-bearing `ManagedResource { resourceName,
  resourceClass, resourceDestroy :: FilePath -> IO ExitCode }` record + `perRunManagedResources`
  (the three per-run stacks, destroy = the same `PulumiCommand`s the cascade used), the pure
  `pairPerRunResidue` (pairs each per-run resource with its already-batched `ResidueStatus`,
  preserving the single MinIO port-forward) and `resourcesToDestroy` (the present ones; absent
  skipped; unreachable skipped per the per-run graceful-degradation rule), and `reconcileAbsent`
  (destroy the present resources in canonical order, fail-fast, with the per-run destroy
  narration).
- `runNativeDeleteCascade` step 3 routed through `reconcileAbsent` (behavior-preserving: same
  stacks, same `PulumiCommand`s, same canonical order, same narration). `perRunCascadeInventory`
  + its tests removed in favor of `pairPerRunResidue` / `resourcesToDestroy` / `reconcileAbsent`.

### Boundary note vs. the original plan

The default `rke2 delete` / `aws teardown` stay **refuse-gates** (Sprint 4.19/4.20's
`residueBlocksTeardownGate`), not active reconcilers — making them `reconcileAbsent` would
contradict their gate contract. `reconcileAbsent` is the **active-destroy** engine; this sprint
adopts it in the cascade per-run phase. `aws teardown`'s active-destroy
(`--destroy-pulumi-residue`) and `nuke` adopt it in Sprint 7.8 / a follow-on, where idempotent
re-run of a re-runnable command genuinely pays off.

### Validation

`prodbox check-code` exit 0; `prodbox test unit` 584/584 (new tests: `pairPerRunResidue` order,
`resourcesToDestroy` present/absent/unreachable filtering, `reconcileAbsent` destroy-order +
fail-fast via injected fakes); `prodbox test integration cli` 30/30; `prodbox test integration
env` 30/30. **Live smoke**: `prodbox rke2 delete --cascade --yes` on this (clusterless) host
ran the rewired cascade clean to exit 0 — per-run residue all unreachable → `reconcileAbsent`
correctly emitted "skipped (no live per-run residue)", drain skipped, uninstall + postflight
tag sweep clean.

### Remaining Work

The present→destroy path's full live exercise (`rke2 delete --cascade` with live per-run
residue) rolls up with the next operator-driven AWS-substrate cascade run, consistent with the
Sprint 4.17.a/4.17.b live closure gates.

## Sprint 4.22: Registry ↔ Doc Parity Enforcement in `docs check` ✅

**Status**: Done (2026-05-28). The registry ↔ substrates-doc parity is machine-enforced, and
the follow-on create-call-site coverage lint also landed (2026-05-28) — together these complete
the § 3.1 totality enforcement (registry ↔ doc parity + create-site coverage). See Remaining Work
for the precise — deliberately narrow — surfaces the coverage scan covers.
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs` (`renderRegisteredResourcesMarkdown`),
`src/Prodbox/CheckCode.hs` (new `resource-lifecycle-classes` `GeneratedSectionRule`; new
`checkCreateCallSiteCoverage` lint with pure helpers `pulumiCreateSiteViolations` /
`pulumiCreateSiteOwners` / `iamCreateSiteViolations` / `iamCreateVerbs`),
`DEVELOPMENT_PLAN/substrates.md` (markers + `**Generated sections**` metadata)
**Docs to update**: ✅ `documents/engineering/code_quality.md`,
✅ `documents/documentation_standards.md` (§11), ✅ `DEVELOPMENT_PLAN/substrates.md`

### Objective

Make the managed-resource registry the **machine-enforced** SSoT for the documented resource
inventory — drift between the code registry and the doc fails the build — the totality
invariant from
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Deliverables (landed)

- The `DEVELOPMENT_PLAN/substrates.md` Resource Lifecycle Classes inventory is a **generated
  section** (`<!-- prodbox:resource-lifecycle-classes:start/end -->`) rendered from
  `Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses` by the deterministic
  `renderRegisteredResourcesMarkdown`, registered as a `GeneratedSectionRule` in
  `src/Prodbox/CheckCode.hs`. `prodbox docs check` fails the build if the doc table drifts from
  the registry; `prodbox docs generate` regenerates it. So a resource cannot be added to /
  removed from the registry without the documented inventory updating in lockstep — registry ↔
  doc parity is structurally enforced.

### Validation

`prodbox check-code` exit 0; `prodbox docs check` exit 0; `prodbox lint docs` exit 0 (markers ↔
`**Generated sections**` metadata agree); `prodbox test unit` 585/585 (renderer test:
`renderRegisteredResourcesMarkdown` emits every registered resource + class).

### Remaining Work

**Landed (2026-05-28): create-call-site coverage lint.** The follow-on hardening — the
create-call-site coverage scan that complements the registry ↔ doc parity — is now in
`check-code` as `checkCreateCallSiteCoverage` (wired into `haskellStyleViolations`). To avoid the
false-positive risk that originally deferred it, the scan is **deliberately narrow**: it covers
only the two surfaces where prodbox actually originates a new AWS/cluster resource, and the
decision logic is factored into pure, unit-tested helpers.

1. **Pulumi stack creation.** Every `Pulumi<Word>Resources` constructor token in
   `src/Prodbox/CLI/Command.hs` (`PulumiEksResources`, `PulumiTestResources`,
   `PulumiAwsSubzoneResources`, `PulumiAwsSesResources`) must map — via the explicit
   `pulumiCreateSiteOwners` table — to a stack name present in the registry's
   `PerRun`/`LongLived` classes. A new creation constructor with no registry entry, or a mapped
   stack name missing from `resourceLifecycleClasses`, fails the lint (`pulumiCreateSiteViolations`).
2. **Operational IAM user creation.** The AWS CLI verbs `create-user`, `create-access-key`,
   `put-user-policy` (`iamCreateVerbs`) may appear only in the `operational-iam-user` owner
   module `src/Prodbox/Aws.hs`. Their appearance in any other `src/Prodbox/**.hs` file fails the
   lint (`iamCreateSiteViolations`). `CheckCode.hs` itself is excluded from the scan so its own
   verb literals do not self-trigger.

**Deliberately out of scope** (would false-positive; not scanned): generic `create*`,
`change-resource-record-sets` (the § 6a bootstrap DNS record), `create-bucket`, `mc mb`, and
other resource origination that is Pulumi-managed (covered transitively by the stack scan) or
specially-handled. Broadening the scan to arbitrary mutation tokens is what the original
deferral warned against. Together with the already-landed registry ↔ doc parity, this completes
the [§ 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md) totality enforcement
(no undocumented registry change **and** no unregistered create call site on the two scanned
surfaces).

## Sprint 4.23: Per-Run EKS Destroy Drains the Cluster First (DependencyViolation Fix) ✅

**Status**: Done (2026-05-30) — code-owned surface landed 2026-05-29; live closure confirmed
by `prodbox test all` run #6 on the home substrate. See the **2026-05-30 — live closure**
paragraph at the end of this sprint for the verification.
**Implementation**: `src/Prodbox/Infra/AwsEksTestStack.hs`
(`destroyAwsEksTestStackStatus` now calls the new best-effort helper
`drainAwsEksClusterBeforeDestroy` immediately before `pulumiDestroyEither`; new helper
`buildAwsEksDrainEnv` builds the `KUBECONFIG` + `AWS_*` env-var list mirroring
`Prodbox.CLI.Rke2.buildDrainEnvironment`; reuses
`Prodbox.Lifecycle.K8sDrain.drainAwsAffectingK8sResources` unchanged).
**Docs to update**:
`documents/engineering/lifecycle_reconciliation_doctrine.md` (per-run EKS destroy now drains
first), `DEVELOPMENT_PLAN/README.md`.

### Objective

Close the root cause of the May 28/29 leak incident: the per-run `aws-eks-test` Pulumi destroy
path does **not** drain the EKS cluster's AWS-affecting K8s resources (LoadBalancer Services, ALB
Ingresses, Delete-reclaim PVCs) before `pulumi destroy`, so it races AWS's async ENI cleanup. On
both May 28 and May 29 the live `lifecycle` validation's per-run EKS destroy hit
`DependencyViolation: subnet … has dependencies and cannot be deleted` (orphan ENIs from the EKS
cluster's CNI / ELBs lagging async cleanup) after a 20-minute wait.

Sprint 4.17.b already gave the `prodbox rke2 delete --cascade` path a substrate-aware drain
(`runCascadeDrainPhase` + `buildDrainEnvironment` in `src/Prodbox/CLI/Rke2.hs`), but the
**per-run `pulumi eks-destroy` path** — which the harness postflight
(`prodbox pulumi eks-destroy --yes` from `awsPostflightDestroyActions`) goes through — did not.
This sprint extends Sprint 4.17.b's drain to that per-run destroy path.

### The fix

Inject the drain into the eks-destroy path itself
(`AwsEksTestStack.destroyAwsEksTestStackStatus`), immediately before the `pulumi destroy` and
after operational credentials are resolved. Because **both** the harness postflight
(`prodbox pulumi eks-destroy --yes`) and the cascade
(`Prodbox.Lifecycle.ResourceRegistry.reconcileAbsent` → `PulumiEksDestroy`) route through
`destroyAwsEksTestStack`, injecting the drain there covers both. The drain targets the per-run
EKS cluster's own kubeconfig (`.prodbox-state/aws-eks-test/kubeconfig`, materialized during
`ensureAwsEksTestStackResources` per Sprint 4.18) — not the host substrate's cluster — with
`AWS_*` projected from the already-resolved operational `Credentials` (with the
admin-simulation fallback from `loadOperationalAwsCredentials`).

Best-effort + safe-on-unreachable, scoped to the EKS stack:

- If the EKS kubeconfig file is **absent** (e.g. the stack is already partially gone, or a
  standalone `prodbox pulumi eks-destroy --yes` ran in a process that never materialized it),
  the drain is skipped with a diagnostic and the destroy proceeds.
- `drainAwsAffectingK8sResources` probes reachability first, so an unreachable-but-present
  kubeconfig yields `DrainSkipped` and the destroy proceeds.
- A drain **failure** or **timeout** NEVER hard-fails the destroy — the destroy is the goal; the
  worst case is the pre-4.23 behavior (race AWS's async ENI cleanup, possibly `DependencyViolation`,
  which Sprint 7.10 then preserves operational creds for so the orphans can be destroyed on
  retry).
- Only the EKS stack (`aws-eks-test`) gets the drain; the `aws-test` / `aws-eks-subzone` stacks
  are not EKS clusters (no in-cluster K8s to drain).

### Limitation

The drain reuses the on-disk EKS kubeconfig rather than re-materializing it from the backend
snapshot (which would add a MinIO-backend round-trip just to drain). Within a single
`prodbox test all` run the kubeconfig is present (bootstrap → validations → postflight destroy),
so the harness postflight path drains. A standalone `prodbox pulumi eks-destroy --yes` in a
fresh process that never ran the ensure step finds no kubeconfig and skips the drain (then
destroys) — the smallest safe version. The full DependencyViolation-free guarantee is therefore
established only for the harness-driven path (and the cascade, when the kubeconfig is present);
the live closure gate confirms it end-to-end.

### Validation

Fast gates (no live AWS):

- `prodbox check-code` → exit 0.
- `prodbox test unit` → all pass.
- `prodbox test integration cli` / `env` → exit 0 each.
- `prodbox docs check` / `prodbox lint docs` → exit 0.

### Remaining Work

- **Live closure gate (deferred):** a full `prodbox test all` whose per-run `aws-eks-test`
  destroy succeeds without `DependencyViolation` on subnet deletion. This is a flaky live-AWS
  behavior dependent on AWS's async ENI cleanup timing and is not fast-gate-validatable.

**2026-05-30 — live closure (sprint Done).** `prodbox test all` run #6
on the home substrate closed the live gate. The `lifecycle` validation
passed (it had failed in run #3 with `DependencyViolation` on subnet
deletion). The drain ran live — the validation body logged
`Per-run EKS drain (cluster=aws-eks-test-cluster): deleting LoadBalancer
Services...` — and the subsequent `pulumi destroy` succeeded.
Post-run AWS state was verified clean: operational `aws.*` empty,
zero EKS / VPCs / EC2, only the retained admin-managed IAM users
(`prodbox-admin-temp`, `prodbox-ses-smtp`) remained. The full
`prodbox test all` roll-up: 16/17 green (only `keycloak-invite`
failed, a known Sprint 8.5 operator-driven gap, unrelated to this
sprint).

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - AWS substrate environment and
  Pulumi boundary after broad local-cluster decoupling.
- `documents/engineering/aws_test_environment.md` - retained AWS substrate environment doctrine.
- `documents/engineering/cli_command_surface.md` - canonical Haskell lifecycle and public
  AWS-validation Pulumi surface, including the hermetic `prodbox rke2 delete --yes`
  success-summary contract.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - SSoT for the
  reconciler-with-predicates pattern, the state-lifetime rule, and the leak-class
  inventory that Sprints `4.10`–`4.13` operationalize.
- `documents/engineering/code_quality.md` - final non-Python quality gate.
- `documents/engineering/dependency_management.md` - final Haskell dependency and container-image
  inventory, including the `ghcup` pin and no-symlink doctrine for Haskell-build containers.
- `documents/engineering/local_registry_pipeline.md` - Harbor-first lifecycle ordering and the
  authoritative Harbor-plus-storage-backend bootstrap doctrine.
- `documents/engineering/prerequisite_doctrine.md` - lifecycle and Pulumi prerequisite checks.
- `documents/engineering/streaming_doctrine.md` - user-visible success-summary versus actionable
  failure-context rules for noisy lifecycle subprocesses.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage contract after the
  lifecycle/chart rewrite, including the delete-side cleanup-summary contract.
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
