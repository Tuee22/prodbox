# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md), [../documents/engineering/README.md](../documents/engineering/README.md)

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Closure Status

As of April 21, 2026, Phases `0-7` are `Done`. Phase `4` reopened briefly to correct the
Harbor/bootstrap split and then closed again after destructive lifecycle revalidation: the
supported lifecycle now bootstraps MinIO from public `quay.io/minio/*` refs before Harbor
population, reconciles MinIO back onto Harbor-backed refs after the registry is healthy, and
retries alternate configured public-image upstreams when a preferred source fails during Harbor
publication. Phase `7` is also closed: the isolated `aws_admin.*` boundary now survives the full
aggregate rerun, and the canonical `./.build/prodbox test all` flow passes end to end.

The canonical closure gates remain the `prodbox` surfaces defined by this plan: the `.build`
artifact contract, `prodbox check-code`, built-frontend `cli` and `env` suites, the named native
validation flows behind `prodbox test integration ...`, and the clean-room rerun owned by Phase
`6`. The implementation details for those surfaces live in the phase documents and the component
inventory rather than in a validation log here.

The repository now contains:

- one compiled Haskell `prodbox` binary owning the full supported command surface
- one Haskell-owned CLI, config, lifecycle, Pulumi, gateway, chart, AWS, and test surface
- one direct `Dhall -> Haskell types` config contract rooted at operator-authored repository-root
  `prodbox-config.dhall`, with `prodbox config setup` writing that file and `.gitignore`
  excluding it from version control
- one test-harness-only stored-admin-credential exception under `prodbox-config.dhall` `aws_admin.*`
  consumed only by the native IAM validation harness
- one native validation harness for the named real-world proof surfaces behind
  `prodbox test integration ...`
- one YAML-Pulumi infrastructure path with no Python runtime dependency
- zero Python implementation, Python toolchain, or Python bridge artifacts in the repository
- one explicit cleanup ledger, now empty again after the Phase `4` bootstrap-order cleanup landed

Sprint `1.2` closes on the direct-Dhall config contract, native validation harness, and
doc harmony: the operator-facing host artifact contract is enforced at `./.build/prodbox`, the
named validation payloads behind `prodbox test integration ...` are executable native Haskell
validation flows, `prodbox config compile` is removed, `prodbox-config.json` is not part of the
supported repository contract, and the governed docs plus root guidance docs listed in Sprint
`1.2` are aligned with the Haskell-only repository state.

The rewrite followed the seed rationale in
[../HASKELL_REWRITE_PLAN.md](../HASKELL_REWRITE_PLAN.md) and the canonical phase model required by
[development_plan_standards.md](development_plan_standards.md).

## Document Index

| Document | Purpose |
|----------|---------|
| [development_plan_standards.md](development_plan_standards.md) | Conventions for maintaining the development plan |
| [system-components.md](system-components.md) | Authoritative target component inventory for the Haskell rewrite |
| [00-overview.md](00-overview.md) | Target architecture, current baseline, and hard constraints |
| [phase-0-planning-documentation.md](phase-0-planning-documentation.md) | Phase 0: Planning and documentation topology for the rewrite |
| [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) | Phase 1: Haskell runtime, CLI, config, and Pulumi foundations |
| [phase-2-gateway-dns.md](phase-2-gateway-dns.md) | Phase 2: Haskell gateway runtime and DNS ownership |
| [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) | Phase 3: Haskell chart platform and cluster-backed `vscode` delivery |
| [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) | Phase 4: Lifecycle hardening, Pulumi decoupling, and Python removal |
| [phase-5-public-host-validation.md](phase-5-public-host-validation.md) | Phase 5: Public hostname closure and external proof on the Haskell stack |
| [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) | Phase 6: Final clean-room rerun and zero-Python handoff |
| [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md) | Phase 7: Interactive onboarding, AWS IAM, and quota automation in Haskell |
| [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) | Comprehensive ledger of Python-removal and compatibility cleanup work |

## Sprint Status

### Status Vocabulary

| Status | Meaning | Emoji |
|--------|---------|-------|
| **Done** | Deliverables implemented for the sprint-owned surface, validated, and aligned in docs | ✅ |
| **Active** | Work has started and remaining implementation or documentation work is explicitly listed | 🔄 |
| **Blocked** | Closure depends on an unmet prerequisite or prior sprint closure | ⏸️ |
| **Planned** | Ready to start once execution reaches the sprint in sequence | 📋 |

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Its deliverables are implemented in the worktree.
2. Its validation commands pass through the canonical `prodbox` surface.
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned blocker or remaining work survives.

## Phase Overview

| Phase | Name | Status | Document |
|-------|------|--------|----------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ Done | [phase-0-planning-documentation.md](phase-0-planning-documentation.md) |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ Done | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ Done | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | ✅ Done | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ Done | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | ✅ Done | [phase-5-public-host-validation.md](phase-5-public-host-validation.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ Done | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | ✅ Done | [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md) |

**Status interpretation**: Phase `1` owns canonical Dockerfile placement and the frontend
container-build doctrine. Phase `2` owns gateway packaging and DNS ownership. Phase `3` owns the
`vscode-nginx` Harbor delivery contract plus supported chart proof. Phase `4` owns Harbor-first
steady-state image sourcing, the bootstrap exception for Harbor and storage-backend prerequisites,
idempotent public-image population, dual-arch publication, and mixed-arch cluster support. Phases
`5-6` own the public-host proof and clean-room handoff. Phase `7` owns interactive onboarding,
IAM automation, quota management, and the isolated elevated-credential proof harness. All phases
are now closed on their owned surfaces.

**Canonical target architecture**: one Haskell `prodbox` CLI, one operator-authored
repository-root `prodbox-config.dhall` decoded directly into Haskell types with
`prodbox-config-types.dhall` as the shared schema and no supported `prodbox-config.json`
artifact, one supported host runtime (`Ubuntu 24.04 LTS` with systemd), one host build root
`.build/` with the operator-facing binary at `.build/prodbox` (runnable as `./.build/prodbox`),
produced by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy
step, one container build root `/opt/build` owned only by Dockerfiles under `docker/`, one
repository-owned custom-image doctrine
where every custom Dockerfile is single-stage from `ubuntu:24.04` except
`docker/nginx-oidc.Dockerfile`, which may remain based on `nginx:1.25-alpine`, one local RKE2
lifecycle owned by Haskell, one Harbor-first registry pipeline where Harbor and the HA-chart
workloads required to make Harbor's storage backend functional may bootstrap from public
registries but every later supported cluster deployment pulls from Harbor, one idempotent Haskell
reconcile path that ensures required public images and custom images are present in Harbor for both
`amd64` and `arm64` irrespective of local host architecture before those later deployments, one
mixed-arch cluster support contract, one Pulumi integration path retained without Python Pulumi
programs, one in-cluster gateway runtime, one Haskell chart platform, one explicit cleanup or
removal ledger, and one destructive clean-room rerun that closes with no supported-path Python
artifacts left in the repository.

## Current Plan Status

As of April 21, 2026, the development plan is current against the repository worktree, and all
phase-owned closure gates have been revalidated through the canonical `prodbox` surface:

- The repository is Haskell-only. All Python source under `src/prodbox/`, `tests/`, and
  `typings/`, plus Python packaging (`pyproject.toml`, `poetry.toml`, `.python-version`) and
  bridge modules (`Backend/Python.hs`, `PythonEnv.hs`), remain removed.
- The frontend request path and supported-runtime helpers no longer carry Python-era compatibility
  scaffolding: `src/Prodbox/CLI/Command.hs`, `app/prodbox/Main.hs`, and
  `src/Prodbox/SupportedRuntime.hs` now close on direct native Haskell dispatch plus
  Haskell-named context fields only.
- All Pulumi programs are YAML-based: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, and
  `pulumi/aws-test/Main.yaml`. The root `Pulumi.yaml` uses `runtime: yaml`.
- The AWS validation Pulumi programs now take operator-CIDR and SSH-public-key inputs through
  explicit Pulumi stack config synchronized by `src/Prodbox/Infra/AwsEksTestStack.hs` and
  `src/Prodbox/Infra/AwsTestStack.hs`, not via `std:getenv` provider lookups inside the YAML
  runtime.
- `CheckCode.hs` owns `prodbox check-code` and runs `cabal build --builddir=.build all`, then
  syncs the operator-facing binary to `.build/prodbox`.
- `TestRunner.hs` owns `prodbox test ...`, runs the Haskell suites via `cabal test`, and executes
  the named real-world validation flows through `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/TestRunner.hs` and `src/Prodbox/TestValidation.hs` now re-invoke the native CLI
  through the canonical `./.build/prodbox` path during aggregate and validation workflows, so
  nested suite-side binary syncs do not strand later phases on a deleted executable inode.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/Prerequisite.hs`, and `src/Prodbox/EffectInterpreter.hs`
  now gate AWS-backed named suites on validated AWS credentials, Route 53 access, Pulumi login,
  and native IAM harness readiness during Phase `1/2` prerequisite checks, so blocked
  environments fail before entering the validation bodies.
- `src/Prodbox/EffectInterpreter.hs` now proves the Pulumi-login prerequisite against the
  canonical repo-backed MinIO backend by port-forwarding MinIO, ensuring the
  `prodbox-test-pulumi-backends` bucket exists, and running `pulumi whoami` under the same
  explicit backend environment used by the supported lifecycle rather than ambient host Pulumi
  login state.
- The supported config contract is direct `Dhall -> Haskell types`: `src/Prodbox/Settings.hs`
  decodes and validates the operator-authored repo-root `prodbox-config.dhall` without
  materializing `prodbox-config.json`, and the public `prodbox config` surface is
  `setup|show|validate`.
- Missing repo-root config now fails fast with explicit `./.build/prodbox config setup` guidance
  instead of surfacing a raw file-open exception from the Dhall loader.
- `src/Prodbox/Aws.hs` now keeps the public `config setup` and public `aws ...` command family on
  interactive temporary elevated credentials, while stored `aws_admin.*` remains a test-harness-only
  exception owned by `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/SupportedRuntime.hs` now contains only the retained supported-runtime helpers; the
  retired non-test `aws_admin.*` recovery path has been removed.
- The canonical validation surfaces are `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, and the named native validation flows listed in
  `src/Prodbox/TestValidation.hs`.
- The named integration suites `aws-iam`, `dns-aws`, `aws-eks`, `pulumi`, `ha-rke2-aws`,
  `gateway-daemon`, `gateway-pods`, `gateway-partition`, `charts-platform`, `charts-storage`,
  `charts-vscode`, `public-dns`, and `lifecycle` map to executable native Haskell validation
  flows in `src/Prodbox/TestValidation.hs`.
- The supported container topology now lives entirely under `docker/`:
  `docker/prodbox.Dockerfile`, `docker/gateway.Dockerfile`, and `docker/nginx-oidc.Dockerfile`.
- `prodbox rke2 delete --yes` now emits a summary-oriented cleanup narrative that reports AWS test
  stack disposition, local substrate cleanup, managed kubeconfig handling, and preserved host
  roots without replaying successful uninstall-script traces or expected missing-resource noise.
- `docker/prodbox.Dockerfile` and `docker/gateway.Dockerfile` are single-stage
  `ubuntu:24.04` builds that preserve the `/opt/build` artifact contract and mount the official
  `haskell:9.6.7-slim` toolchain image as a BuildKit context during publication.
- The in-cluster gateway steady state is repo-rootless: `app/prodbox/Main.hs` permits
  repo-rootless `gateway start|status`, `charts/gateway/` injects AWS auth through the
  `gateway-aws-credentials` secret instead of a repo-root JSON mount, the chart health probes hit
  `/v1/state` over HTTP, and `docker/gateway.Dockerfile` installs the official AWS CLI bundle per
  `TARGETARCH` so the Route 53 subprocess path remains available inside the pod.
- `docker/nginx-oidc.Dockerfile` remains the permitted `nginx:1.25-alpine` exception and is now
  published to Harbor through the same dual-arch custom-image flow as the gateway image.
- `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`,
  and `pulumi/home/Main.yaml` now enforce Harbor-backed image references for the steady-state
  supported workloads, explicit required-public-image population, and `amd64` plus `arm64`
  per-platform publication plus manifest reconcile irrespective of local host architecture.
- `src/Prodbox/CLI/Pulumi.hs` now projects configured ZeroSSL EAB credentials into the
  `cert-manager` namespace as `acme-eab-credentials` and wires the supported `ClusterIssuer`
  through `spec.acme.externalAccountBinding` when `acme.eab_*` is set.
- `src/Prodbox/TestRunner.hs` now waits for `prodbox host public-edge` to report
  `CLASSIFICATION=ready-for-external-proof` during supported-runtime bootstrap and postflight, and
  `src/Prodbox/CLI/Rke2.hs` now requires six consecutive successful Harbor `/readyz` plus `/v2/`
  probes before Docker login or image publication continues on a fresh cluster.
- `src/Prodbox/ContainerImage.hs` and `src/Prodbox/CLI/Rke2.hs` now split lifecycle bootstrap from
  Harbor steady state: `prodbox rke2 install` boots Harbor, installs MinIO once from public
  `quay.io/minio/*` refs to establish the local backend, mirrors required public images and
  publishes custom images into Harbor, then reconciles MinIO back onto Harbor-backed refs before
  later supported deployments rely on Harbor.
- The Harbor public-image mirror path now retries alternate configured upstream candidates when a
  preferred source publishes a valid manifest list but later fails during
  `docker buildx imagetools create`, so transient public-registry rate limits do not strand the
  post-bootstrap Harbor reconcile.
- `test/integration/cli/Main.hs` now proves that bootstrap split on the built-frontend path by
  recording both the public MinIO bootstrap refs, the publish-time fallback from
  `public.ecr.aws/docker/library/postgres` to `docker.io/library/postgres`, and the later
  Harbor-backed MinIO reconcile.
- The latest reruns now pass `./.build/prodbox check-code`, `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, `./.build/prodbox test integration env`,
  `./.build/prodbox test integration aws-iam`, `./.build/prodbox test integration lifecycle`,
  `./.build/prodbox rke2 install`, and `./.build/prodbox test all`.
- The aggregate rerun now reaches the supported post-test restore state with
  `prodbox host public-edge` reporting `CLASSIFICATION=ready-for-external-proof`.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture rather than the
   Python architecture.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   Pulumi orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from operator-authored
   repository-root `prodbox-config.dhall`, with `prodbox-config-types.dhall` aligned to the
   decoder and no generated `prodbox-config.json` artifact or supported `prodbox config compile`
   path.
4. Public `prodbox config setup` and public `prodbox aws ...` paths can bootstrap all required AWS
   credentials from scratch using temporary elevated credentials entered interactively by the
   operator.
5. `aws_admin.*` may be stored in `prodbox-config.dhall` only as the native IAM test-harness
   exception. No supported non-test command or runtime helper may read or use that section.
6. The operator-facing binary lives at `.build/prodbox` (runnable as `./.build/prodbox`),
   produced by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy
   step.
7. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
8. Every custom Dockerfile is single-stage from `ubuntu:24.04`, except
   `docker/nginx-oidc.Dockerfile`, which may remain based on `nginx:1.25-alpine`.
9. Harbor and the HA-chart workloads required to make Harbor's storage backend functional may
   bootstrap from public container registries on the supported path.
10. Every later supported cluster deployment obtains its images from Harbor.
11. `prodbox` idempotently ensures required public images and all custom images are present in
   Harbor after bootstrap and before those later deployments.
12. Both `amd64` and `arm64` image variants or manifests are built, loaded, mirrored, or fetched
   irrespective of the architecture of the machine running `prodbox`.
13. Mixed-arch clusters are supported on the canonical lifecycle and chart-delivery path.
14. Pulumi remains part of the supported architecture, but no supported Pulumi program depends on
   Python.
15. The strongest clean-room rerun passes from full local delete through final AWS teardown using
   the Haskell stack.
16. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
   cleanup.
17. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
