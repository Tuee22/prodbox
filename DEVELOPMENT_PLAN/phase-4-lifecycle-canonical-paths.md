# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[system-components.md](system-components.md), [the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md)
**Generated sections**: none

> **Purpose**: Capture the lifecycle hardening work, Pulumi scope reduction, Python-removal
> work, and the CLI-doctrine adoption sprints that bring the local-cluster lifecycle and AWS
> validation surfaces in line with [> Reconcilers](../documents/engineering/README.md) and `Test Organization`.

## Phase Status

✅ **Reclosed 2026-07-04 for host/RKE2 resource guardrails** — Phase `4` reopened to expand its
own local-cluster lifecycle surface with Sprint `4.41`, now ✅ Done on its code-owned surface.
`prodbox cluster reconcile` reconciles RKE2/kubelet resource reservations, eviction thresholds,
log/image garbage-collection limits, and a systemd resource-control drop-in from the validated
capacity plan, and refuses when observed host capacity is lower than the authored host declaration.
Earlier lifecycle, storage, and teardown closures remain valid; this work adds the runtime
enforcement ring beneath the Phase `1` resource schema and Phase `3` chart rendering. Validation:
warning-clean build, `prodbox test unit` 1167/1167, and `prodbox test integration cli` 40/40. Sprint
`5.13` has since added canonical-suite pod/quota/limit-range validation; the live over-limit pod /
host-availability proof remains a non-blocking Standard O live-proof axis.

✅ **Live-proven 2026-06-26 — the destructive `lifecycle` validation passes under the green home
`test all`.** The `lifecycle` named validation (`cluster delete` → `cluster reconcile` → `cluster
health`, with the suite's postflight per-run AWS destroy) passes `ExitSuccess` in the green home
`prodbox test all` (2026-06-26, 18/18; see [00-overview.md](00-overview.md) Alignment Status), so Phase
4's Vault-before-MinIO reconcile, Model-B object-store, retained-storage topology, and idempotent
teardown surfaces are home-substrate live-proven. The teardown was also hardened this run to close a
non-functional race at the cluster-teardown boundary — an EKS-ENI-detachment wait plus idempotent
`vault unseal` retries so the reconcile→destroy path never strands a freshly-sealed Vault under host
memory pressure (see [README.md](README.md) Closure Status). The `--substrate aws` lifecycle axis stays
orthogonal ([substrates.md](substrates.md)).

✅ **Reclosed 2026-06-09** — Phase 4 was reopened for Sprints `4.26`–`4.27` (design-intention
review: the destructive-command Plan/Apply gaps + the registry-name SSoT consolidation surfaced
against the lifecycle reconciliation surface); both have now landed. Sprint `4.26` ✅ routed
`prodbox rke2 delete` (default + cascade) and `prodbox nuke` through `runPlanWithOptions` so
`--dry-run` / `--plan-file` are honored on the destructive arms (fixing the audit's #1 bug — a
discarded `_planOptions` that silently destroyed), added the `checkPlanOptionsHonored` lint, derived
the default-delete sweep from `perRunManagedResources` (closing the `aws-eks-subzone` omission),
failed the nuke step-4 tag sweep closed, read `nukePlanFile`, wired `noLiveLongLivedPulumiStacks`
into the `aws teardown` preflight, and retired `categorizePulumiResidue` — all while preserving the
refuse-gate vs reconciler split ([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
The cascade order was left untouched (drain → destroys; `storage_lifecycle_doctrine.md` §5 was
already corrected in Sprint 0.9). Sprint `4.27` ✅ introduced the `StackDescriptor` SSoT (deriving the
per-run/long-lived name lists, CLI verbs, project dirs, and a generated registry-name↔CLI-command doc
section), wrapped the Route 53 capability-proof create→delete in `bracketOnError` (unregistered — no
steady state), generalized `iamCreateSiteViolations` → `awsCreateSiteViolations`, and renamed
`longLivedStackNames` → `longLivedResourceNames`. Validation at reclosure: `check-code` 0,
`test unit` 802, `integration cli` 35, `prodbox-daemon-lifecycle` 11/11, `lint docs` 0, `docs check`
0; the live destructive cascade is operator-driven. All earlier Phase 4 sprints (`4.1`–`4.25`) remain
`Done` on their owned surfaces.

The phase was previously reopened for Sprint `4.24`: the public-edge production certificate
joins the managed-resource registry as a `LongLived` resource (now `Done` on the code-owned
surface), and for Sprint `4.25`, which makes `prodbox rke2 delete` a no-op success when no RKE2
cluster is installed (`Done`).

✅ **Reclosed 2026-06-16 (Vault secret-management refactor)** — Phase 4 reopened for Sprints
`4.29` (Vault folded into the canonical cluster lifecycle — reconcile deploys/unseals, teardown
preserves the durable Vault PV) and `4.30` (MinIO opaque-object-ID metadata hardening + sealed-state
red-team). Sprints `4.29` through `4.33` are now `Done`; Sprint `4.33` closes the Haskell-side
sealed-state residue gate, redaction, and opaque-namespace audit surface.
**Extended 2026-06-13** with Sprint `4.31` (the unified deterministic
retained-storage topology — a machine-id-free `.data/<namespace>/<StatefulSet>/<replica>` layout
under one reconciler, with MinIO and `vscode` converted to StatefulSets), also now ✅ Done. All
earlier Phase 4 sprints remain `Done` on their owned surfaces; the authoritative reopen narration is
the [README.md → Closure Status](README.md#closure-status) entries of the same dates. Sprint `4.31`
refines the canonical retained-storage paths — it extends, it does not reverse, the Phase `3`
storage-binding model (Sprint `3.1`).

✅ **Finalized 2026-06-14 (Vault-root finalization + cluster federation)** — the secrets model is
finalized: Vault is the sole secrets/KMS/PKI root, the master-seed HMAC derivation model is retired
(not extended), `FileSecret` / Secret-mounted plaintext Dhall is removed (not bridged), and a sealed
Vault fail-closed-bricks the cluster. Sprints `4.29` and `4.30` are reframed to own that finalized
end state (no bridge; derivation retired), and Phase 4 is extended with Sprint `4.32` (federated
lifecycle reconcile — child clusters auto-unseal from their parent on the init-once /
unseal-on-rebuild contract, the fail-closed unseal cascade bricks a subtree when a parent is
sealed/unreachable, and root-config writes are gated on the root Vault token), now `Done`. The
federation trust topology this lifecycle wiring depends on is owned by Sprint `3.20` (Vault
transit-seal hierarchy) and the new
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). All
earlier Phase 4 sprints remain `Done` on their owned surfaces; the authoritative reopen narration is
the [README.md → Closure Status](README.md#closure-status) 2026-06-14 entry. Sprint `4.32` extends,
it does not reverse, the Sprint `4.29` retained-Vault-PV lifecycle and the Phase `3` storage-binding
model.

✅ **Refined 2026-06-15 and reclosed 2026-06-16 (Model B object-store + whole-system
zero-child-info)** — the MinIO/Pulumi
encryption strategy is finalized to **Model B**: prodbox owns one application-level Vault-Transit
envelope per object (not MinIO bucket server-side encryption), and the fail-closed invariant is
recognized as a whole-system *existence/metadata* property spanning MinIO objects, the host disk,
Kubernetes objects, and logs/output. Sprint `4.30` closed on 2026-06-16 with the **Model B
object-store** — `Prodbox.Minio.ObjectStore` + `Prodbox.Minio.EncryptedObject`
(Vault-keyed-HMAC opaque IDs, the `prodbox-envelope-v2` hashed AAD, the encrypted index payload
shape, and decoy key pool), the `prodbox-state` generic bucket, and the in-force-config read routed
through the opaque object key. Phase 4 is extended with Sprint `4.33` (whole-system
sealed-state scrub of the on-disk, Kubernetes, and log surfaces — residue-query gating behind the
Vault-readiness check, redaction, opaque k8s namespaces, and the cross-surface red-team), now `✅
Done` on its code-owned Haskell surface. Sprint `4.32` (federation) owns the parent-side live child registration writer and child
Vault lifecycle interpreter that consume the downstream-identity-to-Vault-KV custody foundation;
Sprint `4.33` owns the Haskell-side opaque Kubernetes namespace, log, and sealed-state gate
enforcement. Live cross-surface sealed-Vault red-team validation remains Sprint `5.8`, and raw
Pulumi checkpoint decrypt-to-scratch interposition remains Sprint `7.14`.
This **refines, it does not reverse**, the 2026-06-14
finalized model and reopens no new phase; the authoritative narration is the
[README.md → Closure Status](README.md#closure-status) 2026-06-15 entry, and the doctrine SSoT is
[vault_doctrine.md §9/§10](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store).
All earlier Phase 4 sprints remain `Done` on their owned surfaces.

✅ **Done (Sprints `4.1`–`4.23`)** — Sprints `4.1`–`4.4` remain `Done` on lifecycle parity, Python Pulumi removal,
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
`prodbox rke2 delete --yes` runs are hermetic for chatter on the uninstaller's own stdout/stderr,
which the lifecycle-local quiet path filters, while non-zero uninstall exits still surface
actionable upstream context. (The inotify warning `Failed to allocate directory watch: Too many
open files` is emitted out-of-band by systemd/journald to the console and is not capturable by the
quiet path, so it may still appear on a successful run; it is benign — see streaming_doctrine.md §6.)

✅ **Reclosed 2026-07-03 after the AWS EBS block-storage lifecycle reopen** — two new sprints
expanded Phase 4's own lifecycle/teardown surface (narrated in [README.md → Closure Status](README.md) per
rule A). Sprint `4.39` is ✅ Done: the **pre-created EBS volume is a registered managed
resource** (typed `discover`/`destroy`, extending the Sprint `4.20`/`4.22` registry) with
retain-vs-test-scoped tag markers, so production EBS is retained on teardown exactly like `.data/`
and only test-scoped EBS is deletable. Sprint `4.40` is ✅ Done: the **suite postflight
test-EBS reaper** and the retain-safe drain so `Retain` EBS PVs survive teardown while test-scoped
volumes are reaped at suite exit — closing the EBS-leak class that motivated this work. Both extend,
and do not reverse, the Sprint `4.12` K8s-drain and the Sprint `4.20`/`4.24`
resource-lifecycle-class model; the AWS-side static-EBS PV renderer is Phase 7 (Sprint `7.28`) and
the identical-rebinding validation is Phase 5 (Sprint `5.12`). All earlier Phase 4 sprints remain
`Done`/as-tracked on their owned surfaces. The superseded dynamic-`gp2` path is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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

**Independent Validation** (development_plan_standards.md Standard N): Phase 4 is
validatable on its owned surface — the local-cluster lifecycle reconcile/delete paths,
the Pulumi-decoupling and Python-removal surfaces, and the destructive Plan/Apply gates —
without depending on any later phase. Lifecycle, refuse-path, cascade-order, and tag-sweep
logic are exercised on the home/local substrate (with the per-run Pulumi state backend,
AWS substrate stacks, and live tag-sweep against fakes or stubs where a later phase owns
the live dependency) via `prodbox dev check`, `prodbox test unit`, and
`prodbox test integration cli`/`lifecycle`. Per Standard O, each sprint's code-owned
closure rests on those local validations; proofs that need live AWS spend, a deployed
cluster, or an unsealed Vault are tracked as non-blocking `Live-proof: pending` notes and
never gate this phase or an earlier one. AWS-substrate coverage of the same validations is
orthogonal and tracked only in [substrates.md](substrates.md)'s parity table.

## Current Baseline In Worktree

- `src/Prodbox/CLI/Rke2.hs` owns the supported local lifecycle.
- `src/Prodbox/CLI/Rke2.hs` keeps `prodbox rke2 delete --yes` hermetic on success through the
  lifecycle-local `captureToolOutput` quiet path plus the expanded
  `isIgnorableRke2DeleteNoiseLine` filter that classifies inotify warnings (`Failed to allocate
  directory watch: Too many open files`), `Cannot find device`, `semodule: not found`, and
  timestamped `Cleanup completed successfully` lines as benign noise. (The directory-watch warning
  is usually emitted out-of-band by systemd/journald to the console rather than on the uninstaller's
  captured fds, so the quiet path cannot hide it and it may still appear on a successful run; it is
  benign — see streaming_doctrine.md §6.) Non-zero uninstall exits still surface actionable upstream
  lines through `summarizeRke2DeleteFailure`.
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
  `ghcup` in-image, pin GHC `9.12.4`, and do not depend on mounted `haskell:9.6.7-slim`
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
- The explicit repo upgrade to GHC `9.12.4`, including required cabal-bound changes, closes with
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
  Haskell infra modules, while the generated operational `prodbox` IAM provider credential is
  minted into Vault KV (`secret/gateway/gateway/aws`) and `prodbox-config.dhall` carries only a
  `SecretRef.Vault` reference to it — never the plaintext key; the Haskell-owned subprocess
  environment resolves that reference from Vault and projects the credential into Pulumi.
  (Original framing read the provider credential from a stored `prodbox-config.dhall` block;
  reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md).)
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
- Benign upstream uninstall chatter on success that the uninstaller writes to its own stdout/stderr
  is classified as ignorable success-path noise and does not surface as an operator-visible
  red-herring error. The inotify warning `Failed to allocate directory watch: Too many open files`
  is emitted out-of-band by systemd/journald to the console, so the quiet path cannot suppress it
  and it may still appear on a successful run (benign — see streaming_doctrine.md §6).
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

## Sprint 4.10: Decouple Long-Lived Pulumi State Onto a Dedicated S3 Bucket ✅

**Status**: Done on the Sprint-owned historical decoupling surface. Sprint `4.10` moved
`aws-ses` off operational `aws.*` credentials and introduced the retained
`pulumi_state_backend` S3 bucket so the long-lived class was no longer tied to the in-cluster
MinIO lifetime. Retry 21's live exercise ran with `aws-ses` on that long-lived S3 backend while
per-run stacks stayed on MinIO, and both substrate-stack discovery paths reported correctly through
`Prodbox.Lifecycle.LiveResidue`. As of Sprint `7.14`, Pulumi checkpoints for both classes are
superseded by the encrypted Model-B decrypt-to-scratch wrapper; the S3 bucket remains retained for
public-edge TLS material and as an optional first-touch import/delete source for old `aws-ses`
checkpoints. The historical `loadAdminAwsCredentials` helper in
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` and `pulumiSesAdminBaseEnv` in
`src/Prodbox/Infra/AwsSesStack.hs` read a stored admin block; under the corrected model
(scheduled as [Sprint 7.16](phase-7-aws-substrate-foundations.md)) `ensureAwsSesStackResources` +
`destroyAwsSesStackStatus` acquire their elevated/admin credential through the interactive
`SecretRef.Prompt` (the test harness simulating that prompt from `test-config.dhall`), not from a
stored config block. The Sprint `4.10` raw export/import migration body was
superseded by Sprint `7.14`'s encrypted-wrapper-backed first-touch migration command.
`destroyLongLivedPulumiStateBucket` helper added to support Sprint 4.13's nuke step 5.
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
  `region = "us-west-2"`, `key_prefix = "pulumi/"`.
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
- Long-lived stack operations acquire their elevated/admin credential through the interactive
  `SecretRef.Prompt` (the test harness simulating that prompt from `test-config.dhall`'s
  `aws_admin_for_test_simulation.*` fixture) rather than the operational `aws.*` credential. The
  operational `prodbox` IAM user — minted into Vault KV and referenced from
  `prodbox-config.dhall` only as a `SecretRef.Vault` value — is no longer granted retained-bucket
  state access. (Original framing read a stored admin block; reframed per
  [Sprint 7.16](phase-7-aws-substrate-foundations.md).)
- `prodbox pulumi aws-ses-migrate-backend` was introduced as a TTY-gated migration command for the
  historical MinIO-to-S3 move. Sprint `7.14` later rewrote the compatibility path to run through
  `Prodbox.Pulumi.EncryptedBackend` and first-touch import/delete instead of raw export/import.
- `pulumi/aws-ses/Pulumi.yaml` recorded the historical backend URL for direct Pulumi compatibility.

### Validation

1. `prodbox check-code`
2. `prodbox test unit` covers the backend-URL renderer and the
   bucket-spec generator (pure logic).
3. Historical live proof: `aws-ses` remained readable across `rke2 delete` / `rke2 reconcile`
   while authenticated with admin credentials. Sprint `7.14` owns the current live first-touch
   encrypted migration/deletion proof.

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

None for Sprint `4.10`. Current encrypted migration/deletion proof is owned by Sprint `7.14`.

Blocks Sprints `4.11`, `4.12`, `4.13`.

## Sprint 4.11: `rke2 delete` Refuse-Path and Predicate Library ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the cascade-with-live-per-run-stacks path was exercised end-to-end
("Per-run Pulumi destroys: running 3 destroy(s) against MinIO" during
suite preflight + "Per-run Pulumi destroys: running 2 destroy(s) against
MinIO" during postflight); the refuse-path was exercised in the
integration tests (`rke2 delete --yes refuses when the per-run Pulumi
state backend is unreachable` 28/28); the `--cascade` + `--allow-pulumi-
residue` mutual exclusion passed integration tests. Refuse-path +
`--cascade` entry point + predicate library + tag-sweep helpers landed
May 21, 2026; full predicate
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

## Sprint 4.12: K8s Drain Phase and Postflight Tag Sweep ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the per-run EKS drain executed against a live AWS EKS cluster
("Per-run EKS drain (cluster=aws-eks-test-cluster): deleting LoadBalancer
Services, ALB Ingresses, and Delete-reclaim PVCs..." → "Per-run EKS
drain complete; proceeding to `pulumi destroy`."), and the subsequent
per-run `pulumi destroy` succeeded without `DependencyViolation`. The
home-substrate `lifecycle` validation also exercised the drain skip-on-
unreachable path (`K8s drain skipped: Kubernetes API server not
reachable; nothing to drain. Proceeding...`). K8sDrain module +
cascade-wiring landed May 21, 2026;
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

## Sprint 4.13: `prodbox nuke` Total Teardown ✅

**Status**: Done. CLI scaffold + parser + TTY guard + dry-run plan
renderer landed May 21, 2026; the five-step orchestration body landed
May 21, 2026 (composes the existing destroy commands in-process and
acquires its elevated/admin credential through the interactive `SecretRef.Prompt`, prompt-used
once then discarded — the test harness simulating that prompt from `test-config.dhall`'s
`aws_admin_for_test_simulation.*` fixture; reframed per
[Sprint 7.16](phase-7-aws-substrate-foundations.md)); live
end-to-end `nuke` closure completed June 3, 2026.
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
`src/Prodbox/CLI/Rke2.hs` (exports `runNativeDeleteCascade`
so nuke step 2 delegates to the actual cascade arm after the retained
`aws-ses` destroy);
`src/Prodbox/Infra/AwsSesStack.hs` (long-lived SES operations load
raw Dhall config for non-secret settings and acquire their elevated/admin credential through the
interactive `SecretRef.Prompt` — the harness simulating it from `test-config.dhall`'s
`aws_admin_for_test_simulation.*` fixture — sourcing the SES `awsRegion` stack config from the
non-secret topology; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md));
`src/Prodbox/Lifecycle/LiveResidue.hs`
(treats `NoSuchBucket` from the long-lived Pulumi S3 backend as
`ResidueAbsent` while preserving fail-closed behavior for ordinary S3
errors); `src/Prodbox/Aws.hs` (exports `adminAwsEnvironment` so the
orchestration body can reuse the prompt-acquired elevated/admin credential across
steps 3, 4, 5; under the corrected model that credential comes from the interactive
`SecretRef.Prompt`, harness-simulated from `test-config.dhall`, not from Vault or a stored
config block — reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md)).
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
five-step destructive sequence (`aws-ses` destroy while Vault/MinIO are
still live → cascade arm → operational IAM teardown → postflight tag
sweep → long-lived state-bucket destroy) in-process. The elevated/admin credential is acquired
through the interactive `SecretRef.Prompt` (prompt-used once then discarded; the test harness
simulating that prompt from `test-config.dhall`'s `aws_admin_for_test_simulation.*` fixture),
matching the long-lived `aws-ses` and state-bucket paths. There is no stored admin block in
`prodbox-config.dhall`; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md).

2026-06-03 validation refresh: `./.build/prodbox nuke --dry-run`
exits 0 and renders the expected five-step plan (`aws-ses` destroy,
`rke2 delete --cascade` arm, operational IAM teardown, postflight tag
sweep, long-lived state-bucket destroy) plus
`CONFIRMATION_LITERAL=NUKE EVERYTHING`. The live closure gate also
completed on June 3, 2026 via `./.build/prodbox nuke` in a TTY with
the typed literal `NUKE EVERYTHING`: step 1 delegated to
`runNativeDeleteCascade` and completed against an already-absent local
cluster; step 2 treated the already-absent long-lived Pulumi S3 backend
bucket as an idempotent `aws-ses` absence; step 3 cleared the
operational IAM/config surface under the nuke-owned
`AcceptOrphanResidue` policy after the cascade; step 4 reported a
clean postflight tag sweep; step 5 completed the long-lived state-bucket
destroy idempotently. Validation after the live-run fixes:
`./.build/prodbox check-code` exit 0, `./.build/prodbox test unit`
634/634, `./.build/prodbox nuke --dry-run` exit 0, live
`./.build/prodbox nuke` exit 0.

### Remaining Work

- None.

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

## Sprint 4.17: Cascade Canonical Order and Self-Materialize Operational Creds ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the cascade narration printed the then-canonical phase order
(`confirm-MinIO → drain → per-run destroys → uninstall → sweep`; Sprint
`4.40` later inserts the test-EBS reaper before uninstall); the
`lifecycle` validation completed a full `rke2 delete --cascade --yes` on
the home substrate; the per-run AWS substrate validations exercised the
cascade with live `aws-eks-test` + `aws-test` per-run stacks present
("Per-run Pulumi destroys: running 3 destroy(s) against MinIO"), drained
the live EKS cluster's LoadBalancer / ALB / Delete-reclaim PVCs, and
completed without `DependencyViolation` on subnet deletion (Sprint 4.17.b
substrate-aware drain validated live). Every code-owned half landed
May 23, 2026. (a) Credential-fallback half (May 23, 2026 a.m.) — each per-run `loadOperationalAwsCredentials` (in `AwsEksTestStack`, `AwsTestStack`, and transitively `AwsEksSubzoneStack` via re-import) falls back to the harness-simulated elevated/admin prompt (sourced from `test-config.dhall`'s `aws_admin_for_test_simulation.*` fixture; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md)) when the operational `aws.*` `SecretRef.Vault` reference resolves empty. (b) Cascade-order rewrite (May 23, 2026 p.m.) reorders `runNativeDeleteCascade` to the canonical sequence (confirm-MinIO via per-stack `<stack>ResidueStatus` → K8s drain → per-run Pulumi destroys for any `ResiduePresent` stack → RKE2 uninstall + cluster-substrate cleanup → postflight cluster-tag sweep) per [lifecycle_reconciliation_doctrine.md §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md); Sprint `4.40` later inserts the test-EBS reaper between per-run destroys and uninstall. (c) **Postflight tag sweep wiring (May 23, 2026 later session)** — `runCascadePostflightTagSweep` now loads admin credentials via `Prodbox.Infra.LongLivedPulumiBackend.loadAdminAwsCredentials`, builds the AWS env via `Prodbox.Aws.adminAwsEnvironment`, and calls `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` with `tagSweepClusterName = Just awsEksCanonicalClusterName`; an empty result is reported as "clean (no cluster-tagged or prodbox-owned AWS residue)" and a non-empty result is reported with the full `renderTagSweepRefusal` block, while the cascade still returns `ExitSuccess` (best-effort per doctrine §6). When no elevated/admin credential is supplied (home-only operator with no AWS substrate, and no harness-simulated `test-config.dhall` `aws_admin_for_test_simulation.*` fixture), the sweep emits a single-line skip diagnostic explaining that no AWS resources could exist. 4 new unit tests in `test/unit/Main.hs::"Sprint 4.17 postflight tag sweep wiring"` cover the refusal-block ARN/tag rendering, the multi-resource bullet output, the empty-list path, and the `TagSweepInput` record shape. The remaining live operator validation closes the sprint: a real cascade run on this host (or a substrate-equivalent) that exercises the new order end-to-end against a live cluster with at least one per-run Pulumi stack alive.
**Blocked by**: none — every code-owned deliverable is shipped and locally validated. **Live-proof: closed** (development_plan_standards.md Standard O): the real-cascade-against-a-host-with-a-live-`aws-eks`-stack proof is a live-infrastructure axis that never gated this sprint's code-owned closure; it was exercised live on 2026-06-01 via `prodbox test all` retry 21.
**Implementation**: `src/Prodbox/Infra/AwsEksTestStack.hs::loadOperationalAwsCredentials` and `src/Prodbox/Infra/AwsTestStack.hs::loadOperationalAwsCredentials` (May 23, 2026 a.m., in-memory operational→admin fallback). `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` (May 23, 2026 p.m., reordered to confirm-MinIO → drain → per-run destroys → uninstall → postflight sweep; Sprint `4.40` later inserts the test-EBS reaper before uninstall); new helpers `perRunCascadeInventory` (pure, exported, drives test coverage), `runCascadeDrainPhase`, `runCascadePostflightTagSweep`; cascade now consumes the typed `<stack>ResidueStatus` adapter from Sprint 4.16 and skips per-run destroys whose stack reports `ResidueAbsent` (or `ResidueUnreachable` per the per-run lifecycle class). 7 new unit tests in `test/unit/Main.hs::"Sprint 4.17 cascade per-run inventory"` cover all-absent / all-present / individual-stack-present / `ResidueUnreachable`-treated-as-absent permutations. **Tag sweep wiring (May 23, 2026 later session)**: `runCascadePostflightTagSweep` rewritten in `src/Prodbox/CLI/Rke2.hs` to invoke `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` against the admin AWS environment when an elevated/admin credential is supplied (the harness simulating the prompt from `test-config.dhall`'s `aws_admin_for_test_simulation.*` fixture; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md)); new exports `awsEksCanonicalClusterName` on `Prodbox.Infra.AwsEksTestStack` so the cascade can build the canonical `kubernetes.io/cluster/<name>` filter; 4 new unit tests in `"Sprint 4.17 postflight tag sweep wiring"` lift `renderTagSweepRefusal` + `TagSweepInput` invariants out of the live-only path (test count 519/519, up from 515).
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
  `src/Prodbox/Infra/AwsTestStack.hs`) tries the operational `aws.*` credential
  (resolved from its `SecretRef.Vault` reference) first and transparently falls back to the
  harness-simulated elevated/admin prompt (sourced from `test-config.dhall`'s
  `aws_admin_for_test_simulation.*` fixture; reframed per
  [Sprint 7.16](phase-7-aws-substrate-foundations.md)) when
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
  `Prodbox.Aws.withMaterializedOperationalCreds :: IO a -> IO a` whose source under the
  corrected model is the harness-simulated elevated/admin prompt (from `test-config.dhall`),
  materializing operational `aws.*` into the in-memory environment for the body and clearing it
  on exit — never writing a plaintext key into `prodbox-config.dhall` (the generated operational
  `aws.*` is minted into Vault KV and referenced only as a `SecretRef.Vault` value; reframed per
  [Sprint 7.16](phase-7-aws-substrate-foundations.md)). Only required if a future call site needs
  the materializing semantics (today's in-memory fallback satisfies every destroy-path
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
   "confirm-MinIO → drain → per-run destroys → uninstall → sweep" (Sprint
   `4.40` later inserts the test-EBS reaper before uninstall) and
   without the May 22 error message ("operational AWS credentials are
   required to destroy the AWS EKS test stack once a Pulumi stack
   exists: aws.access_key_id must not be empty") because the load helper
   now falls back.

### Remaining Work

All code-owned work is shipped. The postflight tag sweep now invokes
`Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` against
the admin AWS environment when an elevated/admin credential is supplied (the harness simulating
the prompt from `test-config.dhall`'s `aws_admin_for_test_simulation.*` fixture; reframed per
[Sprint 7.16](phase-7-aws-substrate-foundations.md)); the explicit
`Prodbox.Aws.withMaterializedOperationalCreds`
bracket remains an optional ergonomic future addition only if a call
site needs the in-memory materializing semantics (today's in-memory fallback
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

Reorder cascade phases to match the then-doctrine-canonical sequence
`confirm-MinIO → drain → per-run destroys → uninstall → sweep` (later extended
by Sprint `4.40` with the test-EBS reaper before uninstall) so AWS-side
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

## Sprint 4.18: Remove Remaining .prodbox-state Artifacts and Final Lint ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the four-block lifecycle exercise (preserved-data + recovery-escape-hatch +
original-failure-mode + final-cleanup) passed end-to-end on the home
substrate; `prodbox check-code`'s `forbidDotProdboxState` lint enforces
the broadened `.prodbox-state/` write ban across `src/` + `app/` (no
hits today); `grep -rn '\.prodbox-state' src/ app/` returns only
historical comment references, no string literals. First chunk of
code-owned work landed 2026-05-27 on top of Sprint 4.16's source-of-truth
swap:

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

Fourth chunk landed 2026-05-30: the remaining two per-run + long-lived
stacks (`aws-eks-subzone`, `aws-ses`) drop their on-disk snapshot caches
to match chunks 1–3.

- New pure parsers `parseAwsEksSubzoneStackFromOutputs` and
  `parseAwsSesStackFromOutputs` decode the flat `Map Text Text` returned
  by `fetchPerRunStackOutputs` / `fetchAwsSesStackOutputs` into the
  existing `AwsEksSubzoneStackSnapshot` / `AwsSesStackSnapshot` records;
  matching `fetchAwsEksSubzoneStackSnapshotFromBackend` /
  `fetchAwsSesStackSnapshotFromBackend` IO wrappers return the same
  `Maybe <Snapshot>` shape the file cache used to. The destroy paths
  read the live snapshot pre-destroy (stack still present); absent /
  unreachable / unparseable reads fall back to the canonical residue
  scan, matching the old `Nothing` arm.
- All `saveAwsEksSubzoneStackSnapshot` / `loadAwsEksSubzoneStackSnapshot`
  / `clearAwsEksSubzoneStackSnapshot` callsites removed; ditto the
  `aws-ses` equivalents. The file-IO helpers deleted entirely:
  `save`/`load`/`clear`, `awsEksSubzoneStateDir`,
  `awsEksSubzoneSnapshotPath`, `awsSesStateDir`, `awsSesSnapshotPath`,
  `snapshotToJson` / `snapshotFromJson` on both modules.
- `assertNoAwsEksSubzoneStackResidue` / `assertNoAwsSesStackResidue`
  drop the now-unused `Maybe <Snapshot>` parameter (both functions did
  their own AWS-CLI residue check against config-resolved identifiers,
  ignoring the snapshot).
- `finalizeDestroy` on both modules simplifies to `pure (Right
  "destroyed")` — no local file to clear.

Fifth chunk landed 2026-05-30: the cross-invocation kubeconfig file at
`.prodbox-state/aws-eks-test/kubeconfig` is replaced with a per-call
`withEksKubeconfig` bracket; every consumer re-derives the kubeconfig
on demand via `aws eks update-kubeconfig --kubeconfig <mktemp>` rather
than relying on file persistence.

- New `Prodbox.Infra.AwsEksTestStack.withEksKubeconfig :: FilePath -> (FilePath -> IO a) -> IO a`
  internally resolves region from settings + cluster name from the live
  MinIO backend snapshot (`fetchAwsEksTestSnapshotFromBackend`),
  `openTempFile`'s a scoped path, runs `aws eks update-kubeconfig
  --kubeconfig <temp>`, hands the path to the action, and cleans up on
  all exit paths (including async exceptions in the action) via
  `Control.Exception.bracket`. Setup failures (snapshot absent, region
  empty, aws CLI failure) throw via `error` so the bracket's cleanup
  fires and the top-level error handler surfaces a clean failure;
  consumers that want the pre-migration "best-effort" semantic
  (drain skips if kubeconfig unavailable) wrap the bracket in `try`.
- `materializeAwsEksKubeconfig` deleted; the only caller
  (`ensureAwsEksTestStackResources` after the Pulumi up) ignored the
  returned path (the call was purely for cross-invocation file
  persistence, which is gone).
- `awsEksTestKubeconfigPath` + `awsEksTestStateDir` exports removed;
  `PublicEdge.substrateKubeconfigPath` (the hardcoded `.prodbox-state`
  path producer) deleted entirely.
- `drainAwsEksClusterBeforeDestroy` wraps the drain in
  `try (withEksKubeconfig ...)`, preserving the pre-migration
  "skip-with-diagnostic on missing kubeconfig" best-effort semantic.
- `PublicEdge.withSubstrateKubectlEnvironment`,
  `CLI/Charts.withSubstrateEnvironment`,
  `TestValidation.withSubstrateKubeconfigEnv` rewritten to wrap their
  actions in `withEksKubeconfig` on AWS substrate; `KUBECONFIG` +
  `AWS_*` overrides project the temp path instead of the legacy
  `.prodbox-state` path.
- `CLI/Rke2.buildDrainEnvironment` re-shaped to take the
  AWS-kubeconfig path as a `Maybe FilePath` parameter;
  `runCascadeDrainPhase` on AWS substrate wraps the drain in
  `try (withEksKubeconfig ...)` and treats bracket-setup failure as a
  hard cascade failure (same severity as a skipped drain — the EKS
  cluster is the source of the AWS resources the per-run destroys would
  delete, so unreachable kubeconfig = guaranteed
  `DependencyViolation` on subnet deletion).

Sixth chunk landed 2026-05-30: the @aws-test@ HA-RKE2 validation SSH
keypair is migrated off `.prodbox-state/aws-test/id_ed25519{,.pub}`.
Ownership flipped to Pulumi: `pulumi/aws-test/Main.yaml` now declares a
`tls:PrivateKey` resource (ED25519), threads `sshKey.publicKeyOpenssh`
into the cloud-init `ssh_authorized_keys`, and exports
`ssh_private_key: ${sshKey.privateKeyOpenssh}` as a Pulumi output. The
host-side `ssh-keygen` invocation is gone.

- Pulumi side: `publicKey` config input removed; `tls:PrivateKey`
  resource added; `ssh_private_key` output added.
- New `Prodbox.Infra.AwsTestStack.withAwsTestSshPrivateKey :: FilePath -> (FilePath -> IO a) -> IO a`
  fetches `ssh_private_key` from the live MinIO Pulumi backend via
  `LiveResidue.fetchPerRunStackOutputs`, writes the PEM body to an
  `openTempFile` path, chmod 600 via `System.Posix.Files.setFileMode`
  (ssh refuses to use private-key files with group/other-readable
  modes), hands the path to the action, and cleans up via
  `Control.Exception.bracket` on all exit paths including async
  exceptions. Throws via `error` when the backend is unreachable or
  `ssh_private_key` is missing / empty.
- `ensureAwsTestSshKey`, `readSshPublicKey`, `awsTestPrivateKeyPath`,
  `awsTestPublicKeyPath`, `awsTestStateDir`, and the
  `testStackPublicKey` field on `AwsTestStackConfig` all deleted. The
  `publicKey` `pulumi config set --secret` entry in
  `syncAwsTestStackConfig` removed — the Pulumi resource owns the
  keypair end-to-end now, so the host no longer pushes a public key
  through stack config.
- Single consumer (`TestValidation.verifyAwsTestSshReachability`)
  rewritten to wrap the per-node SSH retry loop in
  `AwsTest.withAwsTestSshPrivateKey`.
- Unit test `retries AWS test-stack SSH validation until a node accepts
  connections` updated: the mock outputs JSON now includes
  `ssh_private_key`, the pre-migration `.prodbox-state/aws-test/`
  fixture setup is gone.

**Remaining (code-owned)**: none on the code-owned surface. The
`forbidDotProdboxState` lint landed 2026-05-31 (later session) as
`checkForbidDotProdboxState` in `src/Prodbox/CheckCode.hs`, wired into
`haskellStyleViolations`. Scope: scans `src/` + `app/` Haskell string
literals (via `extractStringLiterals`) for the closed `.secrets.json`
cache filename; allowlists `CheckCode.hs` (self-reference) and `test/`
(legitimate regression coverage). Diagnostic names Sprint 3.13 chunks
8–14 as the closure rationale. Three new unit tests cover: fires on an
offending literal, ignores comments, returns `[]` on the current repo
(baseline). The lint is **narrowly scoped** by design — it refuses the
closed `.secrets.json` cache filename, not all `.prodbox-state/*`
writes, because the gateway per-node event-key cache
(`.gateway-event-keys.json` via `resolveGatewayEventKeys`) is still a
legitimate writer pending the daemon self-bootstrap follow-on
described in `Prodbox.Secret.Inventory`. After that follow-on lands,
the lint broadens to refuse any `.prodbox-state/` write path.

**Blocked by**: ~~Sprint 3.13~~ unblocked — Sprint 3.13 chunks 8–14
landed 2026-05-31 and erased every chart-secret cache reference the
lint targets.

**Implementation**: `src/Prodbox/Lib/AwsSubstratePlatform.hs::withTempJsonFile` (system tmp dir; 2026-05-27); `src/Prodbox/CLI/Rke2.hs::pushCustomImageVariantsViaInClusterCrane` (system tmp dir; 2026-05-27); `src/Prodbox/Lifecycle/LiveResidue.hs` (new `fetchPerRunStackOutputs` + `fetchAwsSesStackOutputs` exports + `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` test override; 2026-05-27); `src/Prodbox/PublicEdge.hs::resolveSubstrateHostedZoneId` (live `subzone_id` read; 2026-05-27); `src/Prodbox/TestValidation.hs::verifyAwsEksSnapshot` (live `cluster_name` + `subnet_ids` read; 2026-05-27); `src/Prodbox/Infra/AwsTestStack.hs::parseAwsTestNodesFromOutputs` (new pure decoder; 2026-05-27 later session); `src/Prodbox/Infra/AwsEksTestStack.hs::parseAwsEksTestStackFromOutputs` (new pure decoder; 2026-05-27 later session); `src/Prodbox/TestValidation.hs::verifyAwsTestSnapshot` + `verifyAwsTestSshReachability` + `fetchAwsTestNodes` (live read; 2026-05-27 later session). Third chunk (2026-05-27 later session): `src/Prodbox/Infra/AwsTestStack.hs::parseAwsTestStackFromOutputs` + `fetchAwsTestSnapshotFromBackend` (full-snapshot live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`nodeToJson`/`awsTestSnapshotPath` removed); `src/Prodbox/Infra/AwsEksTestStack.hs::fetchAwsEksTestSnapshotFromBackend` (live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`optionalString`/`awsEksTestSnapshotPath` removed); `src/Prodbox/Lib/AwsSubstratePlatform.hs::ensureAwsSubstratePlatformRuntime` (live read; 2026-05-27 later session). Fourth chunk (2026-05-30): `src/Prodbox/Infra/AwsEksSubzoneStack.hs::parseAwsEksSubzoneStackFromOutputs` + `fetchAwsEksSubzoneStackSnapshotFromBackend` (live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`awsEksSubzoneStateDir`/`awsEksSubzoneSnapshotPath` removed; `assertNoAwsEksSubzoneStackResidue` drops the unused `Maybe <Snapshot>` parameter); `src/Prodbox/Infra/AwsSesStack.hs::parseAwsSesStackFromOutputs` + `fetchAwsSesStackSnapshotFromBackend` (live read via long-lived S3 backend; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`awsSesStateDir`/`awsSesSnapshotPath` removed; `assertNoAwsSesStackResidue` drops the unused `Maybe <Snapshot>` parameter). Fifth chunk (2026-05-30): `src/Prodbox/Infra/AwsEksTestStack.hs::withEksKubeconfig` (new `Control.Exception.bracket`-based scoped-temp-file materializer; `materializeAwsEksKubeconfig` + `awsEksTestKubeconfigPath` + `awsEksTestStateDir` removed; `drainAwsEksClusterBeforeDestroy` wraps in `try`); `src/Prodbox/PublicEdge.hs::substrateKubeconfigPath` deleted; `src/Prodbox/PublicEdge.hs::withSubstrateKubectlEnvironment`, `src/Prodbox/CLI/Charts.hs::withSubstrateEnvironment`, `src/Prodbox/TestValidation.hs::withSubstrateKubeconfigEnv` rewritten to wrap their actions in `withEksKubeconfig` on the AWS substrate; `src/Prodbox/CLI/Rke2.hs::buildDrainEnvironment` re-shaped to take a `Maybe FilePath` AWS-kubeconfig parameter, `runCascadeDrainPhase` wraps the AWS drain in `try (withEksKubeconfig ...)` and treats bracket-setup failure as a hard cascade failure. Sixth chunk (2026-05-30): `pulumi/aws-test/Main.yaml` flips SSH-keypair ownership to Pulumi via a new `tls:PrivateKey` resource + `ssh_private_key` secret output (removes the `publicKey` config input); `src/Prodbox/Infra/AwsTestStack.hs::withAwsTestSshPrivateKey` (new `bracket`-based scoped temp file + `setFileMode` chmod 600 materializer reading `ssh_private_key` from the live MinIO backend; `ensureAwsTestSshKey` / `readSshPublicKey` / `awsTestPrivateKeyPath` / `awsTestPublicKeyPath` / `awsTestStateDir` removed; `AwsTestStackConfig` loses `testStackPublicKey`; the `publicKey` `pulumi config set --secret` entry in `syncAwsTestStackConfig` removed); `src/Prodbox/TestValidation.hs::verifyAwsTestSshReachability` wraps the per-node SSH retry loop in `withAwsTestSshPrivateKey`; the `retries AWS test-stack SSH validation` unit test now injects `ssh_private_key` through the `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` mock.

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

## Sprint 4.24: Public-Edge Production Certificate Registered as a LongLived Managed Resource ✅

**Status**: Done (2026-06-07 on the code-owned surface)
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs`
(`("public-edge-tls", LongLived)` in `resourceLifecycleClasses`),
`src/Prodbox/Lifecycle/ResourceRegistry.hs` (`longLivedManagedResources` +
the `destroyPublicEdgeTlsCertificate` adapter),
`src/Prodbox/Lifecycle/LiveResidue.hs` (`queryPublicEdgeTlsResidueStatus`
`discover`, `destroyRetainedPublicEdgeTls`, the pure
`residueStatusFromObjectListing`, and the `publicEdgeTlsResourceName` /
`publicEdgeTlsRetentionPrefix` constants),
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` (the shared S3 access path:
`listLongLivedObjectKeysUnderPrefix`, `purgeLongLivedObjectsUnderPrefix`,
`parseObjectKeysPayload`, and a prefix-aware `listVersionsPage`),
`src/Prodbox/Lifecycle/Preconditions.hs` (the `noLiveLongLivedPulumiStacks`
gate now also discovers the certificate)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`DEVELOPMENT_PLAN/substrates.md`

### Objective

Register the public-edge production TLS certificate — specifically its retained material in the
long-lived `pulumi_state_backend` S3 bucket — as a typed `ManagedResource` with
`discover`/`destroy`, classified **LongLived** in `resourceLifecycleClasses` (the same class as
`aws-ses`). This reclassifies the cert from disposable `PerRun` chart state to a rate-limited
external resource, so `prodbox check-code` totality
([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md))
covers it and it is never auto-destroyed by `prodbox rke2 delete` or `prodbox aws teardown` —
only by `prodbox nuke` or an explicit destroy. The registration follows the
`lifecycle_reconciliation_doctrine.md § 3.1` totality + soundness pattern.

### Deliverables

- New `ManagedResource` entry for the retained public-edge production certificate
  (`longLivedManagedResources` in `ResourceRegistry.hs`, with the
  `destroyPublicEdgeTlsCertificate` adapter onto the `FilePath -> IO ExitCode`
  `resourceDestroy` shape). ✅
- `LongLived` membership for the certificate in `resourceLifecycleClasses` (declared after
  `aws-ses`). ✅
- `discover` (`queryPublicEdgeTlsResidueStatus`) queries the long-lived S3 store for objects
  under the `public-edge-tls/` prefix and returns a distinct not-present versus unreachable
  outcome via the pure `residueStatusFromObjectListing`: present → `ResiduePresent`, none →
  `ResidueAbsent`, a missing backend bucket → `ResidueAbsent` (the authoritative
  nothing-to-destroy during total teardown, mirroring `residueStatusFromS3Listing`), any other
  S3 failure → `ResidueUnreachable`. `Unreachable → refuse` holds through the single
  `residueBlocksTeardownGate` soundness combinator; it is never silently treated as absent. ✅
- `destroy` (`destroyRetainedPublicEdgeTls` → `purgeLongLivedObjectsUnderPrefix`) removes every
  retained object under the prefix; idempotent (a missing bucket / empty prefix is `Right ()`). ✅
- The generated `substrates.md` Resource Lifecycle Classes table re-renders (via
  `prodbox docs generate`) to include `| `public-edge-tls` | LongLived |`. ✅
- `prodbox check-code` create-site/totality coverage of the new resource — the registry entry
  flows into `resourceNamesOfClass LongLived` and the `checkCreateCallSiteCoverage` lint; the
  certificate is correctly *not* a Pulumi create site (S3-object class), so no
  `pulumiCreateSiteOwners` entry is required. ✅

The certificate is classified the same as `aws-ses`: never reconciled by `prodbox rke2 delete`
or `prodbox aws teardown` (neither touches the `LongLived` class), and removed only by
`prodbox nuke` (transitively, when nuke step 5 destroys the whole long-lived
`pulumi_state_backend` bucket) or by the explicit registered `destroy`. The shared S3
object-level access path added to `LongLivedPulumiBackend.hs` is the foundation that Sprint
`7.11` extends with the substrate-scoped write/key scheme.

### Validation

Closure gates (passed 2026-06-07):

1. `./.build/prodbox check-code` → exit `0`.
2. `./.build/prodbox test unit` → `682/682` (the new
   `Sprint 4.24 retained public-edge TLS certificate managed resource` describe block adds
   8 tests: registry entry + class, name ↔ constant parity, retention-prefix value, and the
   four-way `residueStatusFromObjectListing` present/absent/missing-bucket/unreachable
   discrimination — including `residueBlocksTeardownGate` on the unreachable case — plus the
   `parseObjectKeysPayload` JSON-shape decode). The existing Sprint 4.20 / 7.7 registry tests
   were updated for the new `LongLived` member.
3. `./.build/prodbox docs check` → exit `0` (generated lifecycle-class table parity, now
   including the certificate row).
4. `./.build/prodbox lint docs` → exit `0`.

`prodbox test integration cli` / `env` were also run; the two failures observed in this
environment (`CliSuite.hs:256` / `:376`, both `charts deploy vscode` fake-environment flows)
reproduce identically on the pre-Sprint-4.24 tree and are unrelated to this sprint — the
`charts deploy` command path imports none of the modules this sprint changed.

### Remaining Work

The live production round-trip (issue once → retain → cluster wipe → rebuild → restore, no
re-order) is exercised under Phase 8 Sprint `8.8`.

## Sprint 4.25: `rke2 delete` Is a No-Op Success When No RKE2 Cluster Is Installed ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/cli_command_surface.md`, `README.md`, `CLAUDE.md`

### Objective

Stop `prodbox rke2 delete` from refusing with the Sprint `4.19` fail-closed residue gate
("the per-run Pulumi state backend could not be read … cannot confirm destroyed") when the RKE2
cluster — and with it the in-cluster MinIO state backend — is **already entirely gone**. The
gate alone cannot distinguish "MinIO transiently unreachable while a cluster still exists" from
"no cluster at all", so deleting an already-deleted cluster wrongly exits `1`. When there is no
cluster there is nothing to delete: report `No RKE2 cluster to delete.` and exit `0`.

### Deliverables

- `rke2InstallPresent` (+ `rke2InstallMarkers`, `noRke2ClusterMessage`) in
  `src/Prodbox/CLI/Rke2.hs`: probe the on-disk RKE2 install markers (`/usr/local/bin/rke2`,
  `/usr/local/bin/rke2-uninstall.sh`, `/var/lib/rancher/rke2`, `/etc/rancher/rke2`).
- A no-install short-circuit at the `Rke2Delete` dispatch that precedes the residue gate and the
  cascade, applied uniformly to the default, `--cascade`, and `--allow-pulumi-residue` forms.
- Keyed off **install** state, not service state: an installed-but-stopped RKE2 still has a
  cluster and per-run state on disk and so still flows through the full gate / cascade (the
  Sprint `4.19` fail-closed behavior is preserved unchanged).
- `PRODBOX_TEST_RKE2_PRESENT` test seam (mirrors `PRODBOX_TEST_RESIDUE_*`); `fakeRke2Environment`
  defaults it to `1` so every existing gate/cascade test is unchanged.
- Integration tests (default + `--cascade`) proving the no-op success even when residue reports
  `ResidueUnreachable`.
- Doctrine § 5a documents the carve-out as a no-op short-circuit, categorically distinct from a
  `Precondition`, and explicitly **not** a relaxation of the fail-closed gate.

### Validation

1. `prodbox check-code` exits `0`.
2. `prodbox test unit` and `prodbox test integration cli` pass, including the unchanged
   Sprint `4.19` gate tests and the new no-cluster tests.
3. `prodbox docs check` confirms doc parity.
4. Live: `prodbox rke2 delete --yes` (and `--cascade`) on a host with no RKE2 install prints
   `No RKE2 cluster to delete.` and exits `0`, leaving `.data/` untouched.

### Remaining Work

None — the change is self-contained to the `rke2 delete` dispatch plus its tests and docs.

## Sprint 4.26: Route the Destructive Commands Through `runPlanWithOptions` ✅

**Status**: Done (2026-06-09). `rke2 delete` (default + `--cascade`) and `nuke` now route through
`runPlanWithOptions` — `--dry-run` renders the full destructive plan and exits 0 with **zero**
mutation (the audit's #1 bug: `Rke2Delete flags _planOptions` discarded its options and silently
destroyed), `--plan-file` writes it, and `nuke` now reads `nukePlanFile`. The new
`checkPlanOptionsHonored` lint (in `runDoctrineAlignmentCheck`, proven to fire) forbids a destructive
dispatch arm from binding its `PlanOptions`/`NukeOptions` to a `_` wildcard. The default-delete
per-run sweep is now derived from `perRunManagedResources` (closing the `aws-eks-subzone` omission;
`resourceDestroyCommand` added so the registry is the SSoT for both the destroy and the operator
command string). `nuke` step-4 tag sweep is fail-closed (aborts non-zero before the bucket destroy).
`noLiveLongLivedPulumiStacks` is wired into the operator `aws teardown` preflight (via DI to avoid a
`Preconditions`→`Aws` cycle; the harness `BypassAllResidueForHarnessRefresh` paths are untouched, so
Sprint 7.9's aws-ses relaxation is intact). `categorizePulumiResidue` was retired in favor of the
registry-derived residue path (behavior-preserving). The refuse-gate vs reconciler split is
preserved. The cascade order (drain → destroys) was left untouched. Validation green: `check-code` 0,
`test unit` 790, `integration cli` 35, `lint docs` 0, `docs check` 0. The live destructive cascade is
operator-driven.
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Nuke.hs`,
`src/Prodbox/Native.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/Lifecycle/Preconditions.hs`,
`src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs` (recommended)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`

### Objective

Make `--dry-run` and `--plan-file` honored on the destructive arms — `prodbox rke2 delete`
(default and `--cascade`) and `prodbox nuke` — by routing them through the same
`runPlanWithOptions` Plan / Apply entrypoint the reconcile path already uses
([pure_fp_standards.md#plan--apply](../documents/engineering/pure_fp_standards.md#plan--apply),
Sprint 1.7), close two correctness gaps the audit surfaced (the default-delete sweep omitting
`aws-eks-subzone`; the nuke step-4 tag sweep treating a failed sweep as success), and add a lint
that keeps the wiring honest. The refuse-gate vs reconciler split stays intact: the default
`rke2 delete` and `aws teardown` remain refuse-gates (they refuse on live residue rather than
reconcile it); only `--cascade` reconciles
([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)).

### Deliverables

- `prodbox rke2 delete` (default + `--cascade`) and `prodbox nuke` dispatch through
  `runPlanWithOptions` so `--dry-run` renders the full destructive plan and exits `0` without
  mutation, and `--plan-file` writes the rendered plan. `prodbox nuke` reads its `nukePlanFile`
  field (today threaded into `NukeOptions` but unread).
- A `checkPlanOptionsHonored` lint in `src/Prodbox/CheckCode.hs` forbids any destructive dispatch
  arm from binding its `PlanOptions` to a `_` wildcard, so a future destructive command cannot
  silently drop `--dry-run` / `--plan-file`. Registered in the `prodbox check-code` lint stack
  ([code_quality.md](../documents/engineering/code_quality.md)).
- The default-delete per-run sweep is derived from `perRunManagedResources` rather than a
  hand-maintained stack list, closing the `aws-eks-subzone` omission (the registry is already the
  SSoT for the per-run class after Sprint `4.21`).
- The `prodbox nuke` step-4 tag sweep fails **closed**: a tag-sweep error aborts nuke with an
  actionable error instead of best-effort-continuing, matching the
  [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  "cannot observe is never silently absent" rule for the total-teardown path.
- `noLiveLongLivedPulumiStacks` is wired into the `aws teardown` preflight (completing the
  Sprint `4.11` deferred consolidation note), so `aws teardown` refuses on a live long-lived stack
  the same way it refuses on live per-run stacks.
- `storage_lifecycle_doctrine.md` §5 cascade order: **already corrected in Sprint 0.9** to the
  canonical sequence — confirm-MinIO → **K8s drain → per-run Pulumi destroys** → RKE2 uninstall →
  postflight tag sweep (DRAIN BEFORE DESTROYS, matching
  [lifecycle_reconciliation_doctrine.md §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  and the landed Sprint `4.17.a` reorder). This sprint left it untouched. (An earlier draft of this
  bullet stated the inverted destroys-before-drain order; that was a typo — destroys-before-drain is
  the fatal `DependencyViolation` sequence, NOT canonical.)
- `categorizePulumiResidue` is retired in favor of the registry-derived residue path
  (`perRunManagedResources` + `pairPerRunResidue`), removing the parallel hand-maintained
  classifier the registry now subsumes.

### Validation

1. `prodbox check-code` exits `0`, including the new `checkPlanOptionsHonored` lint.
2. `prodbox test unit` covers the registry-derived default-delete sweep (asserting
   `aws-eks-subzone` is included), the nuke step-4 fail-closed branch, and the
   `noLiveLongLivedPulumiStacks` `aws teardown` preflight composition.
3. `prodbox test integration cli` covers `--dry-run` / `--plan-file` snapshots for
   `rke2 delete`, `rke2 delete --cascade`, and `nuke` (the three destructive `--dry-run` goldens
   are authored under Sprint `5.6`).
4. `prodbox docs check` confirms parity for the corrected `storage_lifecycle_doctrine.md` §5
   cascade order.

### Remaining Work

None — closed 2026-06-09. All deliverables landed; the refuse-gate vs reconciler split is preserved
(default `rke2 delete`/`aws teardown` refuse, only `--cascade` reconciles). The live destructive
cascade against a real cluster/AWS is operator-driven.

## Sprint 4.27: `StackDescriptor` SSoT and AWS Create-Site Generalization ✅

**Status**: Done (2026-06-09). New `src/Prodbox/Infra/StackDescriptor.hs` holds the
`StackDescriptor {stackRegistryName, stackPulumiStackId, stackProjectSubdir, stackCliVerb,
stackLifecycleClass}` SSoT and the single `stackDescriptors` list (recording the `aws-eks`
registry-name vs `aws-eks-test` Pulumi-stack-id difference); the per-run name list (`perRunStackNames`),
CLI verbs, and project subdirs are now DERIVED from it (a unit test pins the derived list equal to
both the prior literal and the `PerRun` registry slice). A new `stack-command-surface`
`GeneratedSectionRule` renders the registry-name↔CLI-command table into `substrates.md` (the typed
source Sprints `0.10`/`5.6` consume). `requireRoute53LifecycleCapability` now wraps its create→delete
probe in `bracketOnError` so the throwaway proof zone is always deleted on a mid-probe exception
(audit C66); it stays unregistered (no steady state) and keeps the create-site lint carve-out.
`iamCreateSiteViolations` was generalized to `awsCreateSiteViolations` (IAM verbs + `create-bucket`,
matching the quoted-arg form; `create-hosted-zone` carved out for the probe). `longLivedStackNames`
was renamed to `longLivedResourceNames` (still derived from the `LongLived` registry class, so it
keeps the non-stack `public-edge-tls` cert). Validation green: `check-code` 0, `test unit` 802/802,
`docs generate`→`docs check` 0, `integration cli` 35/35, `lint docs` 0. The live Route 53
`bracketOnError` cleanup exercise is operator-driven.
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`,
`src/Prodbox/CheckCode.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Dns.hs`,
`test/unit/Main.hs` (recommended)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/cli_command_surface.md`, `DEVELOPMENT_PLAN/substrates.md`

### Objective

Collapse the several hand-maintained parallel lists describing each Pulumi-managed stack
(registry name, Pulumi stack id, project subdir, CLI verb, lifecycle class) into one
`StackDescriptor` SSoT record, and generalize the IAM-specific create-site lint into an
AWS-wide one. This removes the drift risk the documentation-harmony audit flagged between the
registry names, the CLI verbs, and the project directories, and feeds the
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
registry totality from a single typed source.

### Deliverables

- A `StackDescriptor` record (`registryName`, `pulumiStackId`, `projectSubdir`, `cliVerb`,
  `lifecycleClass`) in `src/Prodbox/Aws.hs` (or a dedicated `Prodbox.Infra.StackDescriptor`
  module) as the SSoT for the Pulumi-managed substrate stacks. The per-run / long-lived name
  lists, the CLI verbs, and the project dirs are **derived** from `[StackDescriptor]` rather than
  hand-maintained.
- A generated registry-name↔CLI-command doc section (a `prodbox docs generate` marker block)
  driven by `[StackDescriptor]`; this is the typed source Sprint `0.10` consumes for the
  registry-name↔CLI-verb list and Sprint `5.6` consumes for registry-generated golden coverage.
- The Route 53 capability-proof create→delete is wrapped in `bracketOnError` so a failure after
  the probe record is created always deletes it. It is deliberately **not** registered as a
  `ManagedResource`: the capability probe has no steady state to discover or reconcile, so the
  § 3.1 totality registry stays correct without it.
- `iamCreateSiteViolations` is generalized into `awsCreateSiteViolations` in
  `src/Prodbox/CheckCode.hs` so the create-site lint covers every AWS-resource create call site,
  not only IAM.
- `longLivedStackNames` is renamed to `longLivedResourceNames` (the long-lived class now spans
  more than Pulumi stacks — it includes the public-edge production certificate from Sprint
  `4.24`), with all call sites and the `Prodbox.Lifecycle.Preconditions` /
  `Prodbox.Aws` references updated.

### Validation

1. `prodbox check-code` exits `0`, including the generalized `awsCreateSiteViolations` lint.
2. `prodbox test unit` covers the `StackDescriptor`-derived name lists (per-run / long-lived
   parity with the registry), the CLI-verb derivation, and the renamed `longLivedResourceNames`.
3. `prodbox docs check` confirms the generated registry-name↔CLI-command section round-trips.
4. The Route 53 capability-proof `bracketOnError` cleanup is exercised by the
   `prodbox test integration public-dns` (or `aws-iam`) flow, proving the probe record is deleted
   even on a mid-probe failure.

### Remaining Work

None — closed 2026-06-09. All deliverables landed; the Route 53 capability proof was correctly left
**unregistered** (no steady state). The live `bracketOnError` cleanup exercise is operator-driven.

## Sprint 4.29: Vault Lifecycle Integration and Durable Vault PV Preservation ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Vault.hs`, `src/Prodbox/Vault/Status.hs`, `src/Prodbox/Host.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/vault_doctrine.md`

### Objective

Fold Vault — the sole, finalized secrets/KMS/PKI root — into the canonical cluster lifecycle:
reconcile deploys and unseals it on the init-once / unseal-on-rebuild contract, teardown preserves
its durable PV, and a sealed Vault is a first-class fail-closed cluster status (vault_doctrine §5,
§7, §15). Because Vault is the only secrets backend, a sealed Vault means no secret resolves, no
cert issues, no MinIO object decrypts, and no secret-dependent reconcile step proceeds. The
retained-PV teardown model is extended, not reversed.

### Deliverables

- `prodbox cluster reconcile` deploys/rebinds Vault before MinIO/chart reconcile, runs `vault init`
  **exactly once, ever** (only when the durable PV is empty), and on every subsequent reconcile
  redeploys the Vault chart against existing data and only **unseals** it from the `.age` unlock
  bundle (or prompts) — no re-init and no key regeneration. A cluster rebuild is not a fresh Vault.
- `prodbox cluster delete --yes` and `--cascade --yes` both preserve the durable Vault PV
  (`.data/vault/vault/0`) exactly like the MinIO PV; no `prodbox` command removes it. Vault KV is as
  durable across `cluster delete` + `cluster reconcile` rebuild cycles as any retained PV.
- `prodbox cluster status` / `prodbox edge status` surface Vault sealed/unsealed/uninitialized as a
  first-class line.
- Lifecycle commands gain absolute fail-closed readiness gates: a sealed, unreachable, or
  uninitialized Vault refuses every secret-dependent reconcile step rather than reconstructing any
  secret from a non-Vault source (the master-seed HMAC derivation model is retired, not wrapped).

### Validation

- `cabal build --builddir=.build exe:prodbox` passed, and `.build/prodbox` was refreshed.
- `./.build/prodbox test unit` passed 908/908. Coverage pins the rendered Vault seal-status line
  and the cluster-reconcile plan steps that install Vault before MinIO.
- `./.build/prodbox test integration cli` passed 34/34. Coverage proves the fake RKE2 harness
  emits the Vault status line, waits for `statefulset/vault`, and installs the Vault chart before
  the MinIO chart during `cluster reconcile`.
- Generated CLI docs/goldens were refreshed through the docs generator and the CLI golden harness.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`,
  and `./.build/prodbox dev check` passed after the plan and doctrine updates.

### Remaining Work

None for Sprint `4.29`. Metadata hardening + the red-team sweep land in Sprint `4.30`; the
federated child-cluster auto-unseal and the fail-closed unseal cascade close in Sprint `4.32`.

## Sprint 4.30: Model B Object-Store and MinIO Sealed-State Red-Team ✅

**Status**: Done
**Implementation**: `src/Prodbox/Minio/ObjectStore.hs`, `src/Prodbox/Minio/EncryptedObject.hs`, `src/Prodbox/Crypto/Envelope.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Config/InForce/Core.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/Secret/VaultInventory.hs`, `pulumi/aws-*/Main.yaml`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Build the **Model B object-store** so a sealed Vault reduces every prodbox-owned MinIO bucket to an
opaque, durable ciphertext pile that leaks nothing about the cluster's children — not whether it has
any, how many, where, or what, down to object/key names like `aws`/`aws-eks`. The encryption
strategy is the prodbox application-level Vault-Transit envelope per object (Model B), not MinIO
bucket server-side encryption: content encryption alone leaves object names, prefixes, counts,
sizes, and bucket names as plaintext metadata, but the fail-closed invariant is an
*existence/metadata* property, not just a content property
([vault_doctrine.md §9](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store)).
Because prodbox owns the layer, naming, indexing, and padding live in the same trusted, Vault-bound
code path that does the encryption. Every prodbox-owned object (the in-force cluster config, gateway
state, Pulumi backend state, checkpoints, indexes) is a `prodbox-envelope-v2` Vault-Transit envelope.

### Deliverables

- `src/Prodbox/Minio/ObjectStore.hs` is the typed opaque-name S3 surface (`ensureObjectStoreBucket`
  / `putObject` / `getObject` → `Maybe` / `putIfAbsent` / `listKeys` / `deleteObject`) that
  consolidates the object-store `aws s3api` arg-builders, reuses `minioAwsEnv`
  (`src/Prodbox/Infra/MinioBackend.hs`), verifies the generic bucket before writes, and stages only
  already-enveloped object bytes in a scoped temporary handoff.
- `src/Prodbox/Minio/EncryptedObject.hs` (new) exposes `putLogical` / `getLogical` over a
  `LogicalObject` (`InForceConfig | GatewayState | PulumiStack <id> | DownstreamCluster <id>`) and
  enforces the five Model B rules
  ([vault_doctrine.md §9](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store)):
  - **Vault-keyed-HMAC opaque IDs.** Every object is stored at `objects/<vault-keyed-HMAC>.enc`
    under one flat prefix; the opaque ID is a deterministic, directly addressable,
    index-loss-tolerant HMAC of the logical name, with the MAC key held in Vault KV
    (`vaultKvReadV2`) so a sealed Vault cannot recompute or invert the logical→`objects/<id>.enc`
    mapping. The name carries no signal — not the object's role, not a downstream cluster, not a
    Pulumi stack identity.
  - **`prodbox-envelope-v2` hashed AAD.** `src/Prodbox/Crypto/Envelope.hs` stores
    `base64(SHA256(aad))` in the object body (never the cleartext binding) and carries
    `transit_key` / `created_at` / `key_version` fields; the earlier `prodbox-envelope-v1` wrote a
    literal `base64("clusterId|objectName")` — e.g. `aws-eks` — into the body, a metadata leak even
    while sealed. Open still re-supplies the real AAD via `expectedAad`, so binding strength is
    unchanged; only the stored form is hashed.
  - **Vault-encrypted index.** The id↔logical map lives in `indexes/*.enc`, themselves envelopes; a
    sealed Vault reveals only the opaque IDs, with logical meaning recoverable only once unsealed
    and policy allows the read.
  - **Decoy-pad to a constant object count + size buckets.** A fixed decoy pool keeps a sealed-Vault
    `list-objects` count constant, and object bodies are padded to a small set of fixed size buckets
    so a length histogram reveals nothing.
- The store is parameterized on a `DekCipher` so unit tests use `insecureLocalDekCipher` with no
  live Vault, and the production binding is the Sprint `1.37` `Prodbox.Vault.TransitCipher`.
- **One generically-named bucket.** All prodbox-owned secret-bearing state collapses into a single,
  generically-named bucket; the role-revealing bucket names `prodbox` +
  `prodbox-test-pulumi-backends` are retired, so a bucket-level `s3api ls` carries no signal. (Harbor's
  public image layers stay a separate, non-secret store — the §13 public class, not enveloped.)
- **One object-store, shared across host and daemon accessors.** The pure
  envelope / HMAC-naming / index / decoy layer is identical for both accessors; they differ only in
  the bound Vault-auth `DekCipher` and MinIO transport. The host CLI binds a Transit `DekCipher` via
  the root Vault token and reaches MinIO through `withMinioPortForward`; the in-cluster daemon
  accessor uses the same `EncryptedObject` layer with its own Vault Kubernetes-auth cipher and MinIO
  transport when it has a durable object to read or write. The current gateway daemon keeps its
  runtime state in memory and has no durable MinIO state writer left to migrate in Sprint `4.30`.
- **On-disk consequence.** The hostPath PV that backs MinIO (`.data/prodbox/minio/0`;
  [storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md)) therefore
  holds **only opaque-named ciphertext** — `objects/<hmac>.enc` and `indexes/*.enc` at a constant
  count, with no plaintext name, body, or count distinguishing a real object from a decoy.
- The in-force config production read now routes through the object-store: `Settings` reads the
  Vault-owned object-store HMAC key at `secret/object-store/hmac`, computes the opaque key for
  `LogicalInForceConfig`, fetches from the `prodbox-state` bucket, and then decrypts with the
  Sprint `1.37` Vault-Transit `DekCipher`. The pre-Model-B literal
  `active-config/in-force-config.prodbox-envelope-v1` MinIO helpers are removed from the supported
  backend API.
- The MinIO red-team checklist
  ([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)) is
  exercised for the MinIO + on-disk surfaces; Sprint `4.33` gates the Haskell-side host-disk / k8s /
  log residue/oracle surfaces and the Pulumi backend remains Sprint `7.14`.

### Validation

- `cabal build --builddir=.build exe:prodbox` passes after the object-store integration.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "Model B object store"'`
  passes 9/9, proving the shared generic bucket, typed object-store bucket commands,
  `prodbox-envelope-v2` hashed-AAD non-leak (the object body never contains `aws-eks`),
  HMAC opaque-id determinism, AAD fail-closed behavior, index encode/decode, and the decoy key pool.
- `./.build/prodbox test unit` passes 918/918 and `./.build/prodbox test integration cli` passes
  36/36 after the Model-B object-store integration.
- Source search shows no surviving supported-path `prodbox-test-pulumi-backends`,
  `active-config/in-force-config`, `inForceConfigObjectKey`, or
  `Prodbox.Infra.MinioBackend.fetchInForceConfig` / `storeInForceConfig`; remaining old-name hits
  are historical documentation or negative regression assertions.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`,
  `./.build/prodbox dev lint chart`, and the full `./.build/prodbox dev check` pass.

### Remaining Work

- None on Sprint `4.30`'s owned surface. The raw Pulumi checkpoint interposition remains Sprint
  `7.14`; the Haskell-side host-disk / Kubernetes / log surfaces and exists-vs-`NoSuchKey` oracle
  are now gated by Sprint `4.33`; cross-surface live sealed-Vault validation remains Sprint `5.8`.

## Sprint 4.31: Unified Deterministic Retained-Storage Topology ✅

**Status**: Done
**Implementation**: `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Naming.hs`, `charts/minio/`, `charts/vscode/`, `charts/vault/`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/vault_doctrine.md`

### Objective

Collapse every retained PersistentVolume onto one deterministic host-path scheme —
`.data/<namespace>/<StatefulSet>/<replica-index>` — provisioned by a single reconciler, and make
every stateful workload a StatefulSet so every retained PVC is a `volumeClaimTemplate` claim. This
refines the canonical retained-storage paths; it extends, it does not reverse, the Sprint `3.1`
storage-binding model or the retained-PV teardown contract.

### Deliverables

- `storageBinding` (`src/Prodbox/Lib/Storage.hs`) produces `.data/<namespace>/<StatefulSet>/<ordinal>`
  with no per-host machine-id prefix and no `<release>` / `<claim>` path segment; the deterministic
  PV name derives from `(namespace, statefulset, ordinal)` via
  `Prodbox.Naming.boundedResourceName` through the shared
  `retainedStatefulSetPersistentVolumeName` helper.
- The retained-storage reconciler now walks a typed always-on inventory for MinIO and Vault:
  deterministic PVs + `claimRef`-bound StatefulSet PVCs, host paths
  `.data/prodbox/minio/0` and `.data/vault/vault/0`, and non-root `uid:gid` ownership
  (`1000:1000` for MinIO, `100:100` for Vault). Patroni and `vscode` use the same
  `storageBinding` identity and host-path scheme through their chart release storage specs.
- MinIO moves off the bitnami standalone Deployment to a prodbox-owned `charts/minio/` single-replica
  StatefulSet (mirroring `charts/vault/`); PVC `data-minio-0` → `.data/prodbox/minio/0`. MinIO keeps
  the **public** `quay.io/minio/minio` image at steady state (never the Harbor mirror): it is Harbor's
  own storage backend, so it cannot source its image from Harbor, and unlike the surge-capable bitnami
  Deployment a single-replica StatefulSet cannot break that circular dependency (a Harbor-sourced image
  deadlocks — MinIO down → Harbor 500 → MinIO `ImagePullBackOff`). See
  [local_registry_pipeline.md](../documents/engineering/local_registry_pipeline.md) step 13.
- `vscode` moves from a Deployment to a single-replica StatefulSet; PVC `data-vscode-0` →
  `.data/vscode/vscode/0`.

### Validation

- `cabal build --builddir=.build exe:prodbox` passes after the retained-storage identity refactor.
- Focused units pass: `cabal test --builddir=.build test:prodbox-unit --test-options='-p
  "deterministic storage bindings"'` (1/1) and `cabal test --builddir=.build test:prodbox-unit
  --test-options='-p "vscode deployment plans"'` (1/1).
- `./.build/prodbox test unit` passes 918/918.
- `./.build/prodbox test integration cli` passes 36/36, including the fake-kubectl
  `cluster reconcile` retained-storage manifest proof (`prodbox-retained-prodbox-minio-0`,
  `prodbox-retained-vault-vault-0`, `data-minio-0`, `data-vault-0`) and the chart delete proof for
  `vscode` / Patroni PV cleanup under the `prodbox-retained-<namespace>-<statefulset>-<ordinal>`
  naming scheme.
- Source search shows no surviving supported-path old PV names
  (`prodbox-minio-pv-0`, `prodbox-vault-pv-0`,
  `prodbox-chart-vscode-vscode-vscode-0-data`) outside historical legacy-ledger prose.
- `./.build/prodbox dev lint haskell --write` passes with no HLint hints; `./.build/prodbox dev
  docs check`, `./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and
  `./.build/prodbox dev check` also pass.

### Remaining Work

- None on Sprint `4.31`'s owned surface. The federated child lifecycle closes in Sprint `4.32`, the
  Haskell-side sealed-state scrub closes in Sprint `4.33`, and the live whole-system sealed-state
  proof remains Sprint `5.8`.

## Sprint 4.32: Federated Lifecycle Reconcile and Fail-Closed Unseal Cascade ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lifecycle/FederatedVault.hs`, `src/Prodbox/Vault/Client.hs`, `src/Prodbox/Cluster/Federation.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/Secret/VaultInventory.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cluster_federation_doctrine.md`, `documents/engineering/lifecycle_reconciliation_doctrine.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/config_doctrine.md`

**Closure update (2026-06-16)**: the code-owned federated lifecycle surface has landed. The parent
registration apply path now requires a ready parent root Vault plus `--child-vault-address` and
`--child-kubeconfig`, reads the Vault-owned federation HMAC key, ensures the per-child Transit key,
writes the scoped child token policy, creates the child transit-seal token, records child metadata
under the parent's KV, and applies the child-side `vault/vault-transit-seal-token` Secret without
printing the token. `cluster reconcile` resolves root vs child lifecycle from unencrypted basics:
root clusters keep the Shamir unlock-bundle lifecycle, while child clusters verify parent Vault
readiness, require the parent-provisioned transit-seal token Secret, render the Vault chart with
`seal "transit"`, initialize exactly once with recovery shares, write child init custody back to the
parent's KV, and reuse the parent-custodied child root token for later Vault reconcile and
post-MinIO in-force-config reads. The lifecycle settings order is split so bootstrap-only steps use
repo-root Dhall only until Vault and MinIO are reachable, then reload the in-force settings through
Vault/MinIO before chart and edge work continues.

### Objective

Wire the Vault transit-seal trust tree (Sprint `3.20`) into the canonical cluster lifecycle so a
child cluster's `cluster reconcile` auto-unseals against its parent, the init-once / unseal-on-rebuild
contract holds across the whole hierarchy, and a sealed-or-unreachable parent fail-closed-bricks its
children — the cascade rooted in one operator unsealing the root cluster
([cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md);
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
Mutating the root cluster's in-force config — the keys to the kingdom for every downstream cluster —
is gated on the root Vault token (vault_doctrine §11; config_doctrine §6.2).

### Deliverables

- A **child** cluster's `prodbox cluster reconcile` deploys Vault with `seal "transit"` pointed at
  the parent cluster's Vault and auto-unseals against it — no human, no local unseal keys. A child
  Vault that cannot reach a live, unsealed parent fails reconcile closed with a clear safe error.
- The init-once / unseal-on-rebuild contract (Sprint `4.29`) holds per cluster across the tree: at
  child init the child's recovery keys + initial root token are stored in the parent's Vault KV and
  the parent's transit key is the child's unseal authority; on every subsequent child rebuild Vault
  only auto-unseals against the parent.
- The fail-closed brick cascade is enforced: a sealed/unreachable parent means its children cannot
  unseal, so the whole subtree refuses secret-dependent work — cluster liveness for the tree roots
  in the operator unsealing the root Vault.
- Reads of a cluster's unencrypted basics (cluster id, this cluster's Vault address, seal mode, and —
  for a child — the parent reference it contacts to auto-unseal) stay free; full in-force config
  reads require an unsealed Vault; **writes to the root cluster's in-force config require the root
  Vault token**, wired into the lifecycle so a non-root token cannot mutate root config.

### Validation

- `cabal build --builddir=.build exe:prodbox` passes after the federated lifecycle and settings
  loader changes.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "federated Vault lifecycle"'`
  passes 3/3, including root/child lifecycle classification, child Transit Helm args, and
  sealed/unreachable parent fail-closed rendering.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "cluster federation custody"'`
  passes 8/8, including live-registration readiness rendering and the scoped child seal policy.
- `cabal test --builddir=.build test:prodbox-integration --test-options='-p "Sprint 4.32"'` passes
  1/1 against the built frontend, fake Vault, and fake kubectl, proving live parent registration
  writes the parent-side surfaces and does not print the child token.
- `./.build/prodbox test unit` passes 923/923.
- `./.build/prodbox test integration cli` passes 37/37, including the Sprint `4.32` registration
  proof and the existing native RKE2 reconcile regression surface.
- `./.build/prodbox dev check` exits 0 after the final Sprint `4.32` docs alignment.
- The live two-cluster auto-unseal and sealed-root subtree-brick proof remains operator-driven and
  is carried by the canonical sealed-Vault validation in Sprint `5.8`.

### Remaining Work

- None on Sprint `4.32`'s code-owned lifecycle surface. The gateway-mediated child listing /
  bootstrap-reference surface is closed by Sprint `2.26`; Sprint `4.33` has closed the
  Haskell-side sealed-state gate/redaction/opaque-namespace audit surface; the live sealed-Vault
  federation proof remains Sprint `5.8`.

## Sprint 4.33: Whole-System Sealed-State Scrub: On-Disk, Kubernetes, and Log Surfaces ✅

**Status**: Done (2026-06-16, code-owned Haskell sealed-state scrub surface)
**Implementation**: `src/Prodbox/Lifecycle/LiveResidue.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/StackOutputs.hs`, `src/Prodbox/Infra/LongLivedPulumiBackend.hs`, `src/Prodbox/Lifecycle/`, `src/Prodbox/Vault/`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/streaming_doctrine.md`, `documents/engineering/cluster_federation_doctrine.md`

### Objective

Close the remaining surfaces of the whole-system zero-child-info invariant beyond the MinIO object
bodies that Sprint `4.30` sealed: the host disk, Kubernetes objects, and logs/output. The fail-closed
invariant is a whole-system *existence/metadata* property — when the parent cluster's Vault is sealed
it must be impossible to extract any information about its children across **every** surface, not just
object bodies
([vault_doctrine.md §9 — Whole-system zero-child-info](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store)).
This sprint scrubs the residue-query oracle, the log/output sites, and the Kubernetes object surfaces
so a sealed-Vault combined dump (bucket listing + host-disk walk + ConfigMap/Secret dump + log audit)
yields only `objects/<hmac>.enc` at a constant count and no exists-vs-absent oracle.

### Deliverables

- **Residue-query gating behind the Vault-readiness check.** The MinIO residue discriminators —
  `LiveResidue.residueStatusFromMinioListing`, the `bucketObjectCount` count, and the
  `isAwsCliNoSuchKeyMessage` / `stackPresentInList` exists-vs-absent discriminators — are gated behind
  the Vault-readiness check from Sprint `1.37`, so a sealed-state query for whether a given logical
  object is present never distinguishes "present" from "absent" in its output or error. Presence
  itself is metadata; the exists-vs-`NoSuchKey` oracle is closed
  ([vault_doctrine.md §14](../documents/engineering/vault_doctrine.md#14-error-model-and-logging)).
- **Structured-log / output redaction + redacted `Show`.** Opaque-id and Vault-token types carry a
  redacted `Show` so an opaque ID or token never reaches a log through an incidental `show`; the
  diagnostic sites in `MinioBackend.hs`, `LongLivedPulumiBackend.hs`, `LiveResidue.hs`, and
  `StackOutputs.hs` emit the redacted structured form (`vault_status=sealed component=… result=…`)
  rather than a logical name, a Pulumi stack identity (`aws-eks`), a child-cluster name, or a real
  object count on a sealed path
  ([streaming_doctrine.md](../documents/engineering/streaming_doctrine.md)).
- **Opaque Kubernetes namespaces + downstream-identity-to-Vault-KV audit.** No ConfigMap, Secret,
  namespace name, or other k8s object encodes a downstream-cluster name; child-named namespaces use
  opaque IDs, and downstream kubeconfig/identity is custodied in the parent's Vault KV
  (`secret/clusters/<child-id>/*`), never a k8s Secret. This deliverable is co-owned with the
  federation surfaces in Sprint `4.32`
  ([cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md);
  [vault_doctrine.md §16](../documents/engineering/vault_doctrine.md#16-cluster-federation-a-vault-transit-seal-trust-tree)).
- **Cross-surface red-team.** The sealed-Vault combined sweep — bucket-level `s3api ls` +
  `list-objects` + host-disk walk of `.data/prodbox/minio/0` + k8s ConfigMap/Secret dump + log audit —
  is exercised and reveals only `objects/<hmac>.enc` at a constant count: no role-revealing bucket
  name, no `aws-eks`/stack-name key, no cleartext body, no child-named namespace, and no
  exists-vs-absent oracle
  ([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)).

### Current State

- `queryPerRunResidueStatuses`, `queryAwsSesResidueStatus`, and
  `queryPublicEdgeTlsResidueStatus` consult the host Vault seal-status gate before interpreting
  Pulumi/S3 listings. When Vault is sealed, uninitialized, or unreachable, the query returns one
  uniform `ResidueUnreachable (ResidueQueryFailed "vault_status=... component=residue-query
  result=unobservable")` value and does not expose a stack name, object name, object count, or
  present-vs-absent result.
- `getLongLivedObject` now consults the same gate before classifying `NoSuchKey` for the retained
  public-edge cert object. A blocked gate returns
  `vault_status=... component=long-lived-object result=unobservable` instead of revealing the S3
  key's presence or absence.
- `VaultToken`, `ChildInitCustody`, and `ChildBootstrapCredential` have redacted `Show` instances so
  root/child tokens and recovery keys do not leak through incidental debug rendering.
- The opaque namespace derivation remains `childVaultNamespace`, and the child bootstrap token is
  held in parent Vault KV plus the child-side generic `vault/vault-transit-seal-token` Secret rather
  than a child-named Kubernetes namespace or downstream-identity Secret.

### Validation

- A sealed-state residue query distinguishes neither "present" from "absent" nor a real from a
  decoy-padded object count in its output or error.
- A `prodbox test unit` redaction proof asserts the redacted `Show` for opaque-id / token types and
  that the gated diagnostic sites emit no logical name on a sealed path.
- `cabal build --builddir=.build exe:prodbox` passes.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "Sprint 4.33"'` passes 4/4.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "LiveResidue"'` passes 19/19.
- `./.build/prodbox dev lint haskell --write` reports no hints.
- `./.build/prodbox test unit` passes 928/928.
- `./.build/prodbox test integration cli` passes 38/38.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`, and `git diff --check`
  exit 0.
- `./.build/prodbox dev check` exits 0 after the final Sprint `4.33` implementation validation.

### Remaining Work

- None on Sprint `4.33`'s code-owned Haskell sealed-state scrub surface. The live cross-surface
  red-team is exercised alongside the sealed-Vault canonical validation (Sprint `5.8`), gated on
  the deployed Vault. Raw Pulumi checkpoint decrypt-to-scratch interposition remains Sprint `7.14`.

## Sprint 4.34: Autoscaler Runtime & Federation-Scoped Multi-Cluster Placement ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Scaling/Autoscaler.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`,
`test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the pure
autoscaler reconciler and the trust-tree placement-constraint solver, plus `prodbox test integration
cli`/`env` on the home/local substrate with placement targets stubbed to the local cluster — no
later-phase dependency.
**Docs to update**: `documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/cluster_federation_doctrine.md`

### Objective

Run prodbox itself as the autoscaler reconciler over the capacity type per
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md), constraining
multi-cluster placement to the federation trust tree
([cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md)) so scaling
never perturbs gateway leadership.

### Deliverables

- `src/Prodbox/Scaling/` hosts the prodbox-as-autoscaler reconciler over the typed capacity value on
  the doctrine's check-before-mutate shape.
- Multi-cluster placement candidates are constrained to the federation trust tree; a target outside the
  trust subtree is rejected as inadmissible.
- Scaling actions are ordered so they never disturb the current gateway leader — leadership is preserved
  across scale-up and scale-down.
- `src/Prodbox/Lifecycle/ResourceRegistry.hs` exposes the capacity-scaled resources through the
  managed-resource registry.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `prodbox test unit` (1102/1102; autoscaler planner, trust-tree placement, capacity refusal,
   leader-preserving scale-down, action ordering, and registry exposure)
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox dev check`

### Remaining Work

- None on the Sprint `4.34` code-owned planner surface. Live multi-cluster placement across a
  deployed federation trust tree is a non-blocking `Live-proof: pending` note.

## Sprint 4.35: Pulsar Topics as Managed Resources ✅

**Status**: ✅ Done on code-owned surface 2026-07-03
**Implementation**: `src/Prodbox/Pulsar/Topic.hs`, `src/Prodbox/Pulsar/TopicResidue.hs`, `src/Prodbox/Lifecycle/ResourceClass.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`
**Blocked by**: none — Sprint `3.21` has landed the repo-owned Haskell broker transport/framing.
**Live-proof**: proven 2026-07-03 via `./.build/prodbox test integration pulsar-broker`
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the typed
three-valued broker discover, typed ensure/delete adapters, `ResidueStatus` projection, dynamic
topic-family `LifecycleClass` assignment, and managed-resource destroy adapter, plus `prodbox test
integration cli`/`env` on the home/local substrate with the broker stubbed, plus the live
`pulsar-broker` validation proving broker-backed ensure/discover/delete — no later-phase dependency.
**Docs to update**: `documents/engineering/pulsar_topic_lifecycle_doctrine.md`

### Objective

Register Pulsar topics in the managed-resource registry as first-class typed resources per
[pulsar_topic_lifecycle_doctrine.md](../documents/engineering/pulsar_topic_lifecycle_doctrine.md), so a
topic reconciles present/absent through the same § 3.1 registry totality + soundness pattern as every
other managed resource.

### Deliverables

- ✅ `src/Prodbox/Pulsar/TopicResidue.hs` provides a typed three-valued broker `discover`
  (present / absent / cannot-observe) so "cannot observe" is never silently treated as "absent",
  plus the total projection onto `ResidueStatus`.
- ✅ Typed `ensureTopic` and `deleteTopic` adapters make present/absent reconciliation explicit and
  idempotent at the broker boundary.
- ✅ `src/Prodbox/Lifecycle.ResourceClass` registers dynamic topic-family rows:
  `pulsar-topics-per-run` and `pulsar-topics-long-lived`.
- ✅ `src/Prodbox/Lifecycle/ResourceRegistry.hs` exposes `pulsarTopicManagedResource`, which adapts
  a concrete algebra-derived `ManagedTopic` into the shared managed-resource destroy surface.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror` exit 0.
2. `cabal test --builddir=.build test:prodbox-unit` exit 0 (1157/1157), covering the three-valued
   discover, `ResidueStatus` projection, typed ensure/delete adapters, and registry entry.
3. `./.build/prodbox dev docs generate` exit 0, regenerating the Resource Lifecycle Classes table.
4. `./.build/prodbox test integration cli` exit 0 (39/39).
5. `./.build/prodbox test integration env` exit 0 (39/39).
6. `./.build/prodbox test integration pulsar-broker` exit 0 (2026-07-03): the validation deployed
   the internal Pulsar chart, created and discovered a `persistent://public/default/` validation
   topic through the admin-backed `PulsarTopicBroker`, produced/consumed/acked a CBOR message, then
   deleted the topic and verified broker-backed absence.

### Remaining Work

None.

## Sprint 4.36: Tiered-Storage Budget DSL + Region-Quota Gate + ML Storage Budget ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Capacity/Storage.hs`, `src/Prodbox/Aws.hs`, `test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the
finite-budget capacity reconciler, the region service-quota preflight, and the ML storage-budget totals,
plus `prodbox test integration cli` on the home/local substrate with AWS quota calls stubbed — no
later-phase dependency.
**Docs to update**: `documents/engineering/tiered_storage_capacity_doctrine.md`

### Objective

Implement the finite-budget capacity reconciler, the per-deploy AWS region service-quota preflight, and
the mandatory ML-engine storage budget per
[tiered_storage_capacity_doctrine.md](../documents/engineering/tiered_storage_capacity_doctrine.md).

### Deliverables

- `src/Prodbox/Capacity/` carries a finite-budget capacity DSL with no `Infinite` constructor; MinIO
  unbounded is admissible only when accompanied by an autoscaling-policy witness.
- The per-deploy AWS region service-quota preflight reuses `Prodbox.Aws`'s `applyAwsCheckQuotas` /
  `ensureServiceQuota` so a deploy fails fast when a region quota is insufficient.
- The mandatory ML-engine JIT + model-cache storage budget (host + cluster) is a required input to the
  capacity reconciler.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1106/1106, covering the finite-budget type (no `Infinite`), the
   MinIO-unbounded witness rule, ML storage-budget totals, and insufficient stubbed AWS quota
   refusal.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.
6. `prodbox dev docs check` passed.
7. `git diff --check` passed.
8. `prodbox dev check` passed.

### Remaining Work

- None on the Sprint `4.36` code-owned capacity surface. Live AWS region service-quota checks
  against live AWS credentials are a non-blocking
  `Live-proof: pending` note.

## Sprint 4.37: Lima/WSL2/Incus Provisioning + Native-Arch Build Extension ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Host/Ensure.hs`, `src/Prodbox/DockerConfig.hs`,
`test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the
host-provider selection, the VM ensure reconcilers, and the Docker host-frame gate, plus
`prodbox test integration cli`/`env` on the home/local (Linux/Incus) substrate with foreign-OS providers
stubbed — no later-phase dependency.
**Docs to update**: `documents/engineering/host_platform_doctrine.md`,
`documents/engineering/local_registry_pipeline.md`

### Objective

Provision the host-provider VM per OS — Lima on macOS, WSL2 on Windows, Incus/native on Linux — and run
the native-host-arch image build inside the OS-appropriate Linux frame per
[host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md).

### Deliverables

- `src/Prodbox/Host/` selects the host provider by OS and provides idempotent VM `ensure` reconcilers
  (Lima / WSL2 / Incus/native).
- `src/Prodbox/DockerConfig.hs` extends the existing rule-j host-frame Docker gate so a Windows host
  builds through its WSL2 Linux frame and a macOS host builds through its Lima Linux frame.
- Native-host-arch image build runs inside the OS-appropriate Linux frame, extending the native-arch,
  no-cross-arch-emulation publication contract from Sprint `4.1`.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1110/1110, covering host-provider reconciler selection,
   ready/missing/reboot decisions, wrong-provider fail-fast refusal, and Docker Linux-frame
   dispatch through native Linux, Lima, and WSL2.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.

### Remaining Work

- None on the Sprint `4.37` code-owned host-provider surface. Live macOS-Lima and Windows-WSL2
  provisioning proofs on those hosts are non-blocking
  `Live-proof: pending` notes.

## Sprint 4.38: Substrate-Typed Worker Placement & One-Per-Machine Anti-Affinity ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Cluster/Placement.hs`, `src/Prodbox/Cluster/Topology.hs`,
`test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the
anti-affinity placement solver and the mixed-substrate admissibility rule, plus `prodbox test
integration cli` on the home/local (rke2) substrate — no later-phase dependency.
**Docs to update**: `documents/engineering/cluster_topology_doctrine.md`

### Objective

Place exactly one substrate-typed compute worker per machine per
[cluster_topology_doctrine.md](../documents/engineering/cluster_topology_doctrine.md): node
anti-affinity with `maxSurge: 0`, and mixed-substrate placement admissible only on `rke2`.

### Deliverables

- `src/Prodbox/Cluster/Placement.hs` derives one substrate-typed compute worker per machine using node
  anti-affinity and a `maxSurge: 0` rollout so no two workers co-locate.
- A worker carries its substrate type in the placement so a mismatched-substrate worker is rejected.
- Mixed-substrate placement is admissible only on the `rke2` substrate; every other substrate rejects a
  mixed placement.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1114/1114, covering one-worker-per-machine placement, required
   hostname anti-affinity, `maxSurge = 0`, duplicate-machine refusal, wrong-substrate worker
   refusal, and the mixed-substrate-only-`rke2` rule.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.

### Remaining Work

- None on the Sprint `4.38` code-owned placement surface. Live multi-machine anti-affinity proof on
  a multi-node deployed cluster is a non-blocking
  `Live-proof: pending` note.

## Sprint 4.39: Pre-Created EBS Volumes as a Registered Managed Resource ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs` (the `aws-ebs-volumes`
`LongLived` registry entry), `src/Prodbox/Lifecycle/EbsVolume.hs` (typed EC2
`discover`/`destroy` boundary plus pure JSON/residue adapters),
`src/Prodbox/Lifecycle/TagSweep.hs` (retain-vs-test-scoped markers and EBS tag
partitioning), `src/Prodbox/CLI/Rke2.hs` (substrate-aware retained-inventory projection),
`test/unit/Main.hs`.
**Blocked by**: none — extends the Sprint `4.20`/`4.22` managed-resource registry and the Sprint
`4.24` `LongLived`/`PerRun` classification.
**Live-proof**: pending (the live EKS static-PV materialization and suite postflight EBS reaper are
owned by Sprints `7.28`, `4.40`, and `5.12`; non-blocking per Standard O)
**Independent Validation**: pure unit tests over the EBS discover/destroy decision matrix and the
retain-vs-test-scoped tag partitioning; the generated `resource-lifecycle-classes` table
(`substrates.md`) regenerates from the new registry entry via `prodbox dev docs generate`. No
later-phase dependency.
**Docs to update**: `lifecycle_reconciliation_doctrine.md`, `storage_lifecycle_doctrine.md`,
`substrates.md`, `system-components.md`.

### Objective

Make the pre-created EBS volumes that back the EKS static `Retain` PVs (Sprint `7.28`) a
first-class managed resource with a typed `discover`/`destroy` pair and a lifecycle class, per
[lifecycle_reconciliation_doctrine.md § 1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
and the "no new AWS resource type without a registry entry" rule in
[substrates.md](substrates.md). Encode the production-retain vs test-delete policy in the tag
markers.

### Deliverables

- An EBS-volume entry in `Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses` with typed
  `discover` (`ec2 describe-volumes` filtered by ownership tag) and `destroy` (`ec2 delete-volume`),
  through the harness AWS subprocess layer (never ad-hoc `aws`).
- Tag markers distinguishing retained production EBS (a long-lived retention marker recognized by
  `isRetainedLongLived`/`partitionRetainedLongLived`) from test-scoped EBS
  (`prodbox.io/lifecycle=per-run-test` plus `kubernetes.io/cluster/<name>: owned`).
- Retained-inventory parity: the same deterministic PV/claim names reconciled on AWS as on home,
  through `retainedStorageInventoryEntries SubstrateAws`, which projects the same retained
  namespace/PV/PVC identities as `SubstrateHomeLocal`.
- The generated `resource-lifecycle-classes` table in `substrates.md` regenerated via
  `prodbox dev docs generate`.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` (1095/1095; EBS discover/destroy decision matrix, retained-inventory parity,
   and retain-vs-test-scoped partitioning)
4. `prodbox dev docs generate` (regenerated the `resource-lifecycle-classes` table)
5. `prodbox dev docs check` (generated `resource-lifecycle-classes` table matches the registry)
6. `prodbox test integration cli` (39/39)
7. `prodbox test integration env` (39/39)
8. `prodbox dev check`

### Remaining Work

- None on the Sprint `4.39` code-owned surface. Sprint `4.40` owns the suite postflight
  test-scoped EBS reaper; Sprint `7.28` owns live static EBS PV materialization on EKS.

## Sprint 4.40: Suite Postflight Test-EBS Reaper + Retain-Safe Drain ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/TestRunner.hs` (`awsPostflightDestroyActions` — a test-EBS reaper
step after the stack destroys), `src/Prodbox/CLI/Rke2.hs` (`--cascade` reaper hook + standalone
`aws ebs reap-test --yes` entrypoint), `src/Prodbox/Lifecycle/EbsVolume.hs` (typed reaper plan and
runner), `src/Prodbox/Lifecycle/K8sDrain.hs` (confirm `Retain` EBS PVs survive the drain),
`src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Native.hs`,
`test/unit/Main.hs`, `test/integration/CliSuite.hs`, `test/unit/Parser.hs`, and golden CLI/plan
fixtures.
**Live-proof**: pending
**Independent Validation**: pure unit tests over the reaper's test-scoped-only selection (a
retained-tagged volume is never selected; a test-scoped volume is), the idempotent no-op when
nothing matches, and the retain-safe `Delete`-reclaim drain selector; CLI/env integration runs
exercise the native command surface and fake-tool postflight path. Live-EKS proof that a suite
postflight leaves zero `available` test-scoped EBS volumes rides Sprint `5.12` on the AWS substrate
(Standards N/O).
**Docs to update**: `lifecycle_reconciliation_doctrine.md`, `storage_lifecycle_doctrine.md`,
`substrates.md`.

### Objective

Close the EBS-leak class that motivated this work: cluster/stack teardown RETAINS EBS (production
semantics), while the test harness deletes only test-scoped EBS at suite postflight. The `Retain`
EBS PVs survive the K8s drain (which deletes only `Delete`-reclaim PVCs), and the reaper runs on
every suite exit path (success/failure/Ctrl-C).

### Deliverables

- A test-EBS reaper step in `awsPostflightDestroyActions` that, after the per-run stack destroys,
  deletes only volumes tagged test-scoped (via the Sprint `4.39` discover/destroy), under the
  existing `runWithAwsHarnessCleanup` wrapper so it fires on success, failure, and Ctrl-C.
- A `cluster delete --cascade` reaper hook and `prodbox aws ebs reap-test --yes` standalone
  entrypoint so already-leaked test volumes can be swept on demand; production teardown never
  invokes the reaper.
- Confirmation (and a guard) that `Retain` EBS PVs are not deleted by the drain; the drain's
  `Delete`-reclaim PVC step is a generic safety net only.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1123/1123, covering reaper test-scoped-only selection,
   retained-production exclusion, idempotent no-op, report rendering, parser/command-surface
   coverage, and the `Delete`-only drain selector.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.
6. `prodbox dev docs check`
7. `git diff --check`
8. `prodbox dev check`
9. Leak check (Standard O, live): after a suite postflight, `aws ec2 describe-volumes --filters
   Name=status,Values=available` returns zero test-scoped volumes; a production-mode teardown
   retains durable EBS.

### Remaining Work

- None on the Sprint `4.40` code-owned surface. The live EKS postflight leak check remains a
  non-blocking `Live-proof: pending` axis owned by Sprint `5.12`/AWS substrate parity.

## Sprint 4.41: RKE2 Host Guardrails and Observed-Capacity Refusal [✅ Done]

**Status**: Done (2026-07-04)
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Capacity/Config.hs`,
`src/Prodbox/Host.hs`, `src/Prodbox/Subprocess.hs`, `test/unit/Main.hs`,
`test/integration/CliSuite.hs`
**Live-proof**: pending — on a real local host, prove allocatable cpu/memory/ephemeral-storage are
below physical capacity by the configured reservations and an over-limit pod is OOMKilled/evicted
without starving host SSH/network availability.
**Independent Validation**: pure unit tests over rendered RKE2 config fragments, systemd drop-in
plans, observed-host-capacity comparison, and refusal cases; CLI integration with fake host probes
and fake filesystem/systemctl/kubectl boundaries proves no live cluster is required.
**Docs to update**: `documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/host_platform_doctrine.md`

### Objective

Make the local RKE2 lifecycle enforce the resource plan at the host boundary. The host should stay
responsive even when a prodbox workload leaks memory: Kubernetes should OOM/evict the offending pod
inside declared limits, and RKE2 should never schedule into the host's reserved survival margin.

### Deliverables

- `cluster reconcile` observes host cpu, RAM, node filesystem capacity, and image filesystem
  capacity, then compares those observations against the authored `HostCapacity`. If observed
  capacity is lower, reconcile refuses before mutating the cluster.
- RKE2 config rendering writes a prodbox-owned config fragment for `kubelet-arg` values:
  `system-reserved`, `kube-reserved`, `eviction-hard`, `eviction-soft`,
  `eviction-soft-grace-period`, image-garbage-collection thresholds, and container log caps.
- The rendered kubelet reservations satisfy the Sprint `1.55` lemma
  `rke2.reserved + eviction.floor <= host.physical`.
- A systemd drop-in plan for `rke2-server.service` sets bounded `CPUQuota`, `MemoryHigh`,
  `MemoryMax`, `TasksMax`, and accounting options for the RKE2 process tree. The doctrine notes
  that this protects RKE2/kubelet/containerd processes, while pod limits are enforced through
  Kubernetes cgroups under `/kubepods.slice`.
- `cluster status` reports the authored host budget, observed host capacity, node allocatable
  capacity, and current quota headroom in a structured, non-secret form.

### Validation

1. `prodbox test unit` covering observed-capacity refusal, kubelet arg rendering, systemd drop-in
   rendering, and reservation arithmetic.
2. `prodbox test integration cli` with fake `systemctl`, `kubectl`, and host probes proving
   reconcile plans the guardrails before chart deployment.
3. `prodbox dev check`
4. Live-proof (Standard O): on a real local host, `kubectl describe node` shows allocatable cpu,
   memory, and ephemeral storage below capacity by the configured reservations, and an over-limit
   pod is OOMKilled/evicted without starving SSH/NetworkManager.

### Remaining Work

- None on the code-owned surface. Sprint `5.13` has landed suite-level coverage; the live host
  stress proof is a non-blocking live-infra axis.

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
  inventory that Sprints `4.10`–`4.13` operationalize; for Sprint `4.24` it also records
  the public-edge production certificate as a `LongLived` managed resource under the § 3.1
  totality + soundness pattern; for Sprints `4.26`–`4.27` it records the refuse-gate vs
  reconciler split (default `rke2 delete` / `aws teardown` stay refuse-gates, only `--cascade`
  reconciles), the registry-derived default-delete sweep, the nuke step-4 fail-closed tag sweep,
  and the `StackDescriptor` SSoT feeding the § 3.1 registry totality; for Sprint `4.41` it records
  RKE2/kubelet/systemd resource guardrails as lifecycle-owned reconcile inputs.
- `documents/engineering/resource_scaling_doctrine.md` - for Sprint `4.41`, host/RKE2 reservation,
  eviction-floor, observed-capacity refusal, and runtime enforcement rings.
- `documents/engineering/host_platform_doctrine.md` - for Sprint `4.41`, host capacity observation
  and host-provider-specific filesystem/cgroup capacity facts.
- `documents/engineering/code_quality.md` - final non-Python quality gate; for Sprint `4.26` it
  also lists the `checkPlanOptionsHonored` lint, and for Sprint `4.27` the generalized
  `awsCreateSiteViolations` create-site lint.
- `documents/engineering/dependency_management.md` - final Haskell dependency and container-image
  inventory, including the `ghcup` pin and no-symlink doctrine for Haskell-build containers.
- `documents/engineering/local_registry_pipeline.md` - Harbor-first lifecycle ordering and the
  authoritative Harbor-plus-storage-backend bootstrap doctrine.
- `documents/engineering/prerequisite_doctrine.md` - lifecycle and Pulumi prerequisite checks.
- `documents/engineering/streaming_doctrine.md` - user-visible success-summary versus actionable
  failure-context rules for noisy lifecycle subprocesses; for Sprint `4.33` the cross-linked
  no-name-in-logs and exists-vs-`NoSuchKey` oracle rules for sealed-state output.
- `documents/engineering/config_doctrine.md` - for Sprint `4.30` the in-force config flows through
  the §9 object-store (opaque `objects/<id>.enc`, not the literal `in-force-config` key); for
  Sprint `4.32` the lifecycle bootstrap/in-force-settings split for federated child reconcile.
- `documents/engineering/helm_chart_platform_doctrine.md` - for Sprint `4.30` the
  `.data/prodbox/minio/0` hostPath holds opaque-named ciphertext only.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage contract after the
  lifecycle/chart rewrite, including the delete-side cleanup-summary contract; for Sprint `4.26`
  the §5 cascade order is corrected to the canonical per-run-destroy → drain → uninstall →
  tag-sweep sequence; for Sprint `4.30` the `.data/prodbox/minio/0` hostPath holds opaque-named
  ciphertext only; for Sprint `4.31` the host-path contract is the unified
  `.data/<namespace>/<StatefulSet>/<replica>` scheme (no machine-id prefix), every retained
  workload is a StatefulSet, and one reconciler provisions all retained PVs.
- `documents/engineering/aws_integration_environment_doctrine.md` - additionally, for Sprint
  `4.27`, the `StackDescriptor`-derived per-run / long-lived stack inventory and the generated
  registry-name↔CLI-command section.
- `documents/engineering/unit_testing_policy.md` - native lifecycle and aggregate validation
  ownership.
- `documents/engineering/resource_scaling_doctrine.md` - for Sprint `4.34` the prodbox-as-autoscaler
  reconciler over the capacity type and the federation-scoped multi-cluster placement that never
  perturbs gateway leadership.
- `documents/engineering/pulsar_topic_lifecycle_doctrine.md` - for Sprint `4.35` Pulsar topics as
  managed resources — typed three-valued broker discover, typed destroy, and LifecycleClass assignment,
  reconciled present/absent under the § 3.1 registry pattern.
- `documents/engineering/tiered_storage_capacity_doctrine.md` - for Sprint `4.36` the finite-budget
  capacity DSL (no `Infinite`; MinIO unbounded only with an autoscaling-policy witness), the per-deploy
  AWS region service-quota gate, and the mandatory ML JIT + model-cache storage budget.
- `documents/engineering/host_platform_doctrine.md` - for Sprint `4.37` the host-provider VM
  provisioning (Lima on macOS, WSL2 on Windows, Incus/native on Linux), the Docker host-frame gate,
  and the native-host-arch build inside the OS-appropriate Linux frame.
- `documents/engineering/cluster_topology_doctrine.md` - for Sprint `4.38` one substrate-typed compute
  worker per machine (anti-affinity, `maxSurge: 0`), with mixed-substrate placement admissible only on
  `rke2`.
- [`DEVELOPMENT_PLAN/development_plan_standards.md`](development_plan_standards.md) - SSoT for the
  phase-independence doctrine (Standard N: Phase Independence — the phase-level Independent
  Validation line above; Standard O: Code-Local vs Live-Infra Proof — the non-blocking
  `Live-proof` axis used for the cascade live-closure proof in Sprint `4.17`); this phase defers
  to those standards rather than restating the doctrine.
- [`documents/engineering/vault_doctrine.md`](../documents/engineering/vault_doctrine.md) - SSoT
  for the fail-closed Vault-root secret-management model (Vault is the sole secrets/KMS/PKI root; the
  master-seed HMAC derivation model is retired, not extended); for Sprint `4.29` it records Vault
  folded into the canonical cluster lifecycle on the init-once / unseal-on-rebuild contract (reconcile
  deploys/unseals, teardown preserves the durable Vault PV alongside the MinIO PV, sealed Vault is a
  first-class fail-closed `cluster status` line — vault_doctrine
  [§5](../documents/engineering/vault_doctrine.md#5-vault-deployment-model),
  [§7](../documents/engineering/vault_doctrine.md#7-vault-lifecycle-commands),
  [§15](../documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix)), for
  Sprint `4.30` the Model B object-store — Vault-keyed-HMAC opaque IDs, the `prodbox-envelope-v2`
  hashed AAD, the Vault-encrypted index, decoy-pad-to-constant-count plus size buckets, one
  generically-named bucket shared by the host CLI and the gateway daemon, and the MinIO sealed-state
  red-team (vault_doctrine [§9](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store),
  [§19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)), for Sprint `4.33` the
  whole-system sealed-state scrub of the on-disk, Kubernetes, and log surfaces — residue-query gating
  behind the Vault-readiness check, structured-log/output redaction plus redacted `Show`, opaque k8s
  namespaces with downstream identity in Vault KV, and the cross-surface red-team (vault_doctrine
  [§9 — Whole-system zero-child-info](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store),
  [§14](../documents/engineering/vault_doctrine.md#14-error-model-and-logging),
  [§19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)), and for Sprint `4.32` the
  federated lifecycle reconcile — direct parent-side child registration, child-cluster auto-unseal,
  the fail-closed unseal cascade, parent-custodied child root token reuse, and the post-MinIO
  settings reload. The opaque child-named namespace enforcement landed in Sprint `4.33`. The
  retained-PV teardown model is extended, not reversed.
- [`documents/engineering/cluster_federation_doctrine.md`](../documents/engineering/cluster_federation_doctrine.md) -
  SSoT for the Vault transit-seal trust tree (root/child hierarchy, parent custody of child init
  keys, downstream-cluster metadata as secret, the root-token config-write authority, the fail-closed
  unseal cascade, and the unencrypted basics); for Sprint `4.32` it records the federated lifecycle
  reconcile that auto-unseals a child against its parent and cascades the fail-closed brick down the
  tree when a parent is sealed or unreachable; for Sprint `4.33` it records downstream
  kubeconfig/identity custodied in the parent's Vault KV (`secret/clusters/<child-id>/*`, never a
  k8s Secret) and child-named namespaces using opaque IDs. For
  [Sprint 7.16](phase-7-aws-substrate-foundations.md) the AWS-credential narrative across the
  `aws-ses`, cascade, and `nuke` paths in this phase is reframed onto the corrected three-role
  model — the ephemeral elevated/admin credential enters only through the interactive
  `SecretRef.Prompt` (the harness simulating it from `test-config.dhall`'s
  `aws_admin_for_test_simulation.*` fixture, never a stored block in `prodbox-config.dhall`), the
  generated operational `prodbox` `aws.*` is minted into Vault KV after Vault is unsealed and
  referenced from `prodbox-config.dhall` only as a `SecretRef.Vault` value, and no testing secret
  lives in Vault (vault_doctrine
  [§3](../documents/engineering/vault_doctrine.md), [§4](../documents/engineering/vault_doctrine.md),
  [§13](../documents/engineering/vault_doctrine.md); the `aws_admin_for_test_simulation` block
  specifics in [`aws_admin_credentials.md`](../documents/engineering/aws_admin_credentials.md); the
  per-stack credential-class assignment in
  [`lifecycle_reconciliation_doctrine.md` §2](../documents/engineering/lifecycle_reconciliation_doctrine.md)).

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep lifecycle and AWS IaC doctrine linked from [system-components.md](system-components.md).
- For Sprint `4.24`, cross-reference [substrates.md](substrates.md) so the regenerated Resource
  Lifecycle Classes table lists the public-edge production certificate as `LongLived`.
- For Sprint `4.27`, cross-reference [substrates.md](substrates.md) so the `StackDescriptor` SSoT
  and the renamed `longLivedResourceNames` stay aligned with the Resource Lifecycle Classes
  inventory.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [system-components.md](system-components.md)
