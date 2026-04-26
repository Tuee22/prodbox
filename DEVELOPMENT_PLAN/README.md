# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md),
[../documents/engineering/README.md](../documents/engineering/README.md),
[development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-public-host-validation.md](phase-5-public-host-validation.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Closure Status

As of April 25, 2026, Phase `0` and Phases `5-7` remain complete on their supported repository
surfaces, but Phases `1-4` are active. The current worktree still mounts
`haskell:9.6.7-slim` as the named BuildKit toolchain context in `docker/prodbox.Dockerfile`,
`docker/gateway.Dockerfile`, and `src/Prodbox/CLI/Rke2.hs`, still creates symlinked GHC tool
shims inside the frontend and gateway build images, still carries `base ^>=4.18.2.1` in
`prodbox.cabal`, and still installs Zalando `postgres-operator` from `src/Prodbox/CLI/Rke2.hs`
while mirroring `ghcr.io/zalando/postgres-operator` plus `ghcr.io/zalando/spilo-17` and
targeting `postgresqls.acid.zalan.do`.

The supported architecture remains Haskell-only, Pulumi remains reserved for AWS validation IaC
only, and the revised Haskell-build container doctrine keeps `ubuntu:24.04` as the base image
while requiring in-image `ghcup`, a pinned GHC `9.14.1`, and no symlinked Haskell tool shims in
containers that need Haskell builds. The chart-platform end state remains namespace-local
Percona-operator-backed Patroni PostgreSQL HA for Helm-managed application data. The Harbor
bootstrap exception remains limited to Harbor plus Harbor's storage backend before later Helm
deployments switch to Harbor-backed image refs. Phases `5-7` remain closed on public-host proof,
clean-room rerun, and onboarding/IAM ownership while the earlier container-toolchain and chart
dependencies are reopened.

The canonical closure gates remain the `prodbox` surfaces defined by this plan: the `.build`
artifact contract, `prodbox check-code`, the built-frontend `cli` and `env` suites, the named
native validation flows behind `prodbox test integration ...`, and the destructive clean-room
rerun owned by Phase `6`. Validation details live in the phase documents and the component
inventory rather than in an ad hoc log here.

The repository now contains:

- one compiled Haskell `prodbox` binary owning the full supported command surface
- one supported Haskell-owned CLI, config, lifecycle, Pulumi, gateway, chart, AWS, and test
  surface
- one direct `Dhall -> Haskell types` config contract rooted at operator-authored repository-root
  `prodbox-config.dhall`
- one test-harness-only stored-admin-credential exception under `prodbox-config.dhall`
  `aws_admin.*`
- one native validation harness for the named real-world proof surfaces behind
  `prodbox test integration ...`
- two stack-local YAML Pulumi validation paths under `pulumi/aws-eks/` and `pulumi/aws-test/`
- zero Python implementation, Python toolchain, or Python bridge artifacts in the repository
- one cleanup ledger with four pending non-Python removal items for the current Haskell build-
  container `9.6.7` toolchain-context and symlink surfaces plus the current Zalando Patroni
  operator surface

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
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | 🔄 Active | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | 🔄 Active | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | 🔄 Active | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | 🔄 Active | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | ✅ Done | [phase-5-public-host-validation.md](phase-5-public-host-validation.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ Done | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | ✅ Done | [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md) |

**Status interpretation**: Phases `1-4` are currently `Active`; Phase `0` and Phases `5-7` are
`Done`. Phase `1` owns canonical Dockerfile placement, the direct-Dhall config contract, the
native validation harness, and the reopened frontend container toolchain doctrine. Sprint `1.2`
and Sprint `1.3` remain closed, but Sprint `1.1` is reopened because the current worktree still
uses the mounted `haskell:9.6.7-slim` toolchain context, symlinked GHC tool shims, and pre-
upgrade package bounds for the frontend container path. Phase `2` owns gateway packaging and DNS
ownership; Sprint `2.2` remains closed, but Sprint `2.1` is reopened because the current gateway
container still uses the mounted `haskell:9.6.7-slim` toolchain context and symlinked GHC tool
shims. Phase `3` owns the chart platform, retained storage, Harbor-backed `vscode` delivery, and
the reopened Percona-operator-backed Patroni PostgreSQL doctrine for Helm-managed application
stacks. Sprint `3.1` and Sprint `3.2` remain closed, but Sprint `3.3` is reopened because the
current worktree still uses the Zalando `postgres-operator` surface. Phase `4` owns the Harbor-
first lifecycle, the narrowed Harbor-plus-storage-backend bootstrap exception, AWS-only Pulumi
scope, dual-arch publication, mixed-arch support, and Python removal; Sprint `4.2` and Sprint
`4.3` remain closed, but Sprint `4.1` is reopened because `src/Prodbox/CLI/Rke2.hs` still
publishes Haskell-build custom images through the named BuildKit `haskell-toolchain` context and
the pre-upgrade `9.6.7` toolchain path. Phases `5-7` own public-host proof, the destructive
clean-room rerun, and onboarding/IAM automation, and remain closed on those owned surfaces while
the earlier Phase `1-4` dependencies are open.

## Current Plan Status

As of April 25, 2026, the development plan is current against the repository worktree:

- Sprint `1.1`, Sprint `2.1`, and Sprint `4.1` are active again: the target Haskell-build
  container doctrine keeps `ubuntu:24.04` as the base image but requires in-image `ghcup`, a
  pinned GHC `9.14.1`, no symlinked Haskell tool shims, explicit repo package-bound updates, and
  full canonical validation reruns.
- The current worktree still mounts `haskell:9.6.7-slim` as the named BuildKit toolchain context
  for frontend, gateway, and lifecycle-managed custom-image publication, and still creates
  unversioned GHC tool symlinks inside the frontend and gateway build images.
- `prodbox.cabal` still carries `base ^>=4.18.2.1`, so the explicit repo upgrade to the pinned
  GHC `9.14.1` toolchain is not yet closed.
- Sprint `3.3` remains active: the target chart-platform doctrine requires all supported Patroni
  use to flow through the Percona operator, but the current worktree still installs the Zalando
  `postgres-operator` surface.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- The public `config setup` and public `aws ...` surfaces use prompt-driven temporary elevated AWS
  credentials, while stored `aws_admin.*` remains reserved for the native IAM validation harness.
- The supported container topology lives entirely under `docker/`. Every Haskell-build Dockerfile
  stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and does not
  create symlinked Haskell tool shims; the permitted `docker/nginx-oidc.Dockerfile` Alpine-based
  exception remains unchanged.
- The local lifecycle is Haskell-owned and Harbor-first: Harbor plus Harbor's storage backend may
  bootstrap from public registries, after which required public images and custom images are
  present in Harbor before later Helm deployments proceed.
- The Harbor mirror path retries alternate configured upstreams when publication fails after
  manifest inspection.
- The chart-platform end state is Haskell-owned and renders namespace-local
  Percona-operator-backed Patroni PostgreSQL HA with exactly three replicas, synchronous
  replication, deterministic retained PV bindings, retained secret state, and no embedded
  chart-local PostgreSQL subcharts.
- The reopened Sprint `3.3` keeps the retained Patroni application, standby, and superuser
  secret flow, readiness gate, retained-follower reinitialization, and Keycloak cold-restore
  startup sizing while replacing the current Zalando operator, CRD, image, and Helm repository
  assumptions with the Percona operator surface.
- The supported Pulumi path is Haskell-orchestrated and retained only for the AWS validation
  stacks under `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and
  `pulumi/aws-test/Pulumi.yaml` plus `pulumi/aws-test/Main.yaml`. Non-secret validation inputs are
  synchronized through stack config, while AWS provider credentials stay only in
  `prodbox-config.dhall` and the Haskell-owned subprocess environment.
- The earlier unsupported root `Pulumi.yaml` and `Pulumi.home.yaml` residue for the retired
  local-cluster `pulumi/home` path is removed.
- The canonical validation surfaces are `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, the named native validation flows in
  `src/Prodbox/TestValidation.hs`, and the aggregate reruns `./.build/prodbox test integration all`
  plus `./.build/prodbox test all`.
- On April 25, 2026, local reruns passed `cabal build --builddir=.build exe:prodbox`, sync of
  `./.build/prodbox`, `./.build/prodbox check-code`, `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, `./.build/prodbox test integration env`,
  `./.build/prodbox tla-check`, `./.build/prodbox dns check`,
  `./.build/prodbox test integration aws-iam`, `./.build/prodbox rke2 install`, and
  `./.build/prodbox host public-edge`.
- On April 25, 2026, a direct retained-state rerun also passed
  `./.build/prodbox charts delete vscode --yes` followed by
  `./.build/prodbox charts deploy vscode`.
- On April 25, 2026, fresh aggregate reruns passed `./.build/prodbox test integration all` and
  `./.build/prodbox test all` after the Harbor custom-image inspection repair in
  `src/Prodbox/CLI/Rke2.hs`.
- On April 25, 2026, a final direct rerun of `./.build/prodbox host public-edge` again reached
  `CLASSIFICATION=ready-for-external-proof`.
- Those April 25, 2026 reruns prove the existing pre-upgrade `9.6.7` container path and the
  Zalando-operator-based chart path remain functional; Sprints `1.1`, `2.1`, `3.3`, and `4.1`
  remain open until equivalent proof passes on the `ghcup`-managed GHC `9.14.1`, no-symlink, and
  Percona-operator paths.

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
8. Every custom Dockerfile needing Haskell builds is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims;
   `docker/nginx-oidc.Dockerfile` may remain based on `nginx:1.25-alpine`.
9. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
   upgraded for GHC `9.14.1`, including any required cabal-bound changes and full canonical
   validation reruns on that toolchain.
10. Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
   storage backend during bootstrap.
11. Every later supported Helm deployment obtains its images from Harbor.
12. `prodbox` idempotently ensures required public images and all custom images are present in
   Harbor after Harbor bootstrap and before those later deployments.
13. Both `amd64` and `arm64` image variants or manifests are built, loaded, mirrored, or fetched
   irrespective of the architecture of the machine running `prodbox`.
14. Mixed-arch clusters are supported on the canonical lifecycle and chart-delivery path.
15. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
   cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
   synchronous replication, and no embedded chart-local PostgreSQL subchart.
16. Pulumi remains part of the supported architecture only for true IaC and AWS validation
   resources, and no supported local-cluster platform or application deployment depends on Pulumi.
17. No supported Pulumi program depends on Python.
18. The strongest clean-room rerun passes from full local delete through final AWS teardown using
   the Haskell stack.
19. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
   cleanup.
20. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
