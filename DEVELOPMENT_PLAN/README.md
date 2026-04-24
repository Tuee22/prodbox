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

As of April 23, 2026, Phases `0-5` and `7` are closed on their supported repository surfaces.
Phase `6` remains `Active` only on its post-cleanup rerun surface: the supported architecture is
Haskell-only, Pulumi is reserved for AWS validation IaC only, the chart platform uses
namespace-local Patroni PostgreSQL HA for Helm-managed application data, the Harbor bootstrap
exception is limited to Harbor plus Harbor's storage backend before later Helm deployments switch
to Harbor-backed image refs, and the legacy cleanup residue tracked earlier in this phase is now
removed.

Phase `6` remains open in the current workspace because the final infrastructure-backed rerun has
not been re-executed successfully on this exact checkout after cleanup. The repository root does
not currently contain `prodbox-config.dhall`, so the config-gated closure commands fail fast at
their expected prerequisite boundary before the AWS, DNS, and public-edge payloads begin.

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
- one cleanup ledger with no pending removal items

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
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | 🔄 Active | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | ✅ Done | [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md) |

**Status interpretation**: Phase `1` owns canonical Dockerfile placement, the direct-Dhall config
contract, and the native validation harness. Phase `2` owns gateway packaging and DNS ownership.
Phase `3` owns the chart platform, retained storage, Harbor-backed `vscode` delivery, and the
namespace-local Patroni PostgreSQL doctrine for Helm-managed application stacks. Phase `4` owns
the Harbor-first lifecycle, the narrowed Harbor-plus-storage-backend bootstrap exception,
AWS-only Pulumi scope, dual-arch publication, mixed-arch support, and Python removal. Phases
`5-7` own public-host proof, the destructive clean-room rerun, and onboarding/IAM automation.
Phase `6` remains active until the post-cleanup rerun is repeated successfully from a configured
workspace on the final repository state.

## Current Plan Status

As of April 23, 2026, the development plan is current against the repository worktree:

- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- The public `config setup` and public `aws ...` surfaces use prompt-driven temporary elevated AWS
  credentials, while stored `aws_admin.*` remains reserved for the native IAM validation harness.
- The supported container topology lives entirely under `docker/` and follows the single-stage
  `ubuntu:24.04` doctrine except for the permitted `docker/nginx-oidc.Dockerfile` Alpine-based
  exception.
- The local lifecycle is Haskell-owned and Harbor-first: Harbor plus Harbor's storage backend may
  bootstrap from public registries, after which required public images and custom images are
  present in Harbor before later Helm deployments proceed.
- The Harbor mirror path retries alternate configured upstreams when publication fails after
  manifest inspection.
- The chart platform is Haskell-owned and now renders namespace-local Patroni PostgreSQL HA with
  exactly three replicas, synchronous replication, deterministic retained PV bindings, retained
  secret state, and no embedded chart-local PostgreSQL subcharts.
- The supported Pulumi path is Haskell-orchestrated and retained only for the AWS validation
  stacks under `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and
  `pulumi/aws-test/Pulumi.yaml` plus `pulumi/aws-test/Main.yaml`.
- The earlier unsupported root `Pulumi.yaml` and `Pulumi.home.yaml` residue for the retired
  local-cluster `pulumi/home` path is removed.
- The canonical validation surfaces are `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, the named native validation flows in
  `src/Prodbox/TestValidation.hs`, and the aggregate reruns `./.build/prodbox test integration all`
  plus `./.build/prodbox test all`.
- Phase `6` remains active because
  the post-cleanup rerun on this checkout has not yet completed past the config prerequisite gate.
- On April 23, 2026, the post-cleanup reruns passed
  `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, and `./.build/prodbox tla-check`.
- On the same April 23, 2026 workspace, `./.build/prodbox dns check`,
  `./.build/prodbox host public-edge`, `./.build/prodbox test integration all`, and
  `./.build/prodbox test all` fail fast with the expected guidance because
  `/home/matthewnowak/prodbox/prodbox-config.dhall` is absent.

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
9. Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
   storage backend during bootstrap.
10. Every later supported Helm deployment obtains its images from Harbor.
11. `prodbox` idempotently ensures required public images and all custom images are present in
   Harbor after Harbor bootstrap and before those later deployments.
12. Both `amd64` and `arm64` image variants or manifests are built, loaded, mirrored, or fetched
   irrespective of the architecture of the machine running `prodbox`.
13. Mixed-arch clusters are supported on the canonical lifecycle and chart-delivery path.
14. Every supported Helm-managed PostgreSQL deployment is external, Patroni-based HA with exactly
   three PostgreSQL replicas, synchronous replication, and no embedded chart-local PostgreSQL
   subchart.
15. Pulumi remains part of the supported architecture only for true IaC and AWS validation
   resources, and no supported local-cluster platform or application deployment depends on Pulumi.
16. No supported Pulumi program depends on Python.
17. The strongest clean-room rerun passes from full local delete through final AWS teardown using
   the Haskell stack.
18. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
   cleanup.
19. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
