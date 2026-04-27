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

All phases are currently closed on their owned repository surfaces. The codebase state that those
closures describe is present in the worktree:

- `docker/prodbox.Dockerfile` and `docker/gateway.Dockerfile` install `ghcup` in-image and pin
  GHC `9.14.1`
- `src/Prodbox/CLI/Rke2.hs` no longer uses the lifecycle-managed `haskell-toolchain` BuildKit
  context
- `prodbox.cabal` and `cabal.project` are aligned to the explicit `ghc-9.14.1` path
- the chart and lifecycle surfaces now use the Percona operator rather than the retired Zalando
  operator assumptions

The supported architecture is Haskell-only. The public `prodbox pulumi ...` surface is limited to
the AWS validation stacks under `pulumi/aws-eks/` and `pulumi/aws-test/`, while local-cluster
lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
`src/Prodbox/CLI/Rke2.hs`. The chart-platform end state remains namespace-local
Percona-operator-backed Patroni PostgreSQL HA for Helm-managed application data, and the Harbor
bootstrap exception remains limited to Harbor plus Harbor's storage backend before later Helm
deployments switch to Harbor-backed image refs.

The canonical validation contract is expressed through the `prodbox` commands documented by this
plan: `./.build/prodbox check-code`, `./.build/prodbox test unit`,
`./.build/prodbox test integration cli`, `./.build/prodbox test integration env`, the named
native validations behind `./.build/prodbox test integration ...`, and the clean-room rerun owned
by Phase `6`. Environment-dependent AWS and public-edge proof remain attached to those commands
rather than recorded here as a fresh execution log.

Phases `1-7` are closed on their owned repository surfaces. The repository exposes the complete
supported Haskell command surface described by this plan.

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
- one isolated supported AWS subprocess-auth projection path that ignores ambient host AWS auth
  state and uses only repository-root credentials on supported flows
- one test-suite-only stored admin-credential simulation section under `prodbox-config.dhall`
  `aws_admin_for_test_simulation.*`, modeling the ephemeral elevated credential that a human
  would otherwise enter interactively
- one native validation harness for the named real-world proof surfaces behind
  `prodbox test integration ...`
- two stack-local YAML Pulumi validation paths under `pulumi/aws-eks/` and `pulumi/aws-test/`
- one repo-backed MinIO Pulumi prerequisite and stack-runtime path that uses bounded
  `pulumi login ... --non-interactive` checks and repairs deleted MinIO export host-path mounts
  before validation continues
- zero Python implementation, Python toolchain, or Python bridge artifacts in the repository
- one cleanup ledger with no pending-removal items on the supported path

The rewrite remains on the canonical phase model required by
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

**Status interpretation**: All phases are marked `Done` for their repository-owned surfaces. Each
phase document names the canonical `prodbox` validation commands for its surface; this top-level
plan does not duplicate a live execution log for environment-dependent AWS or public-edge proof.

## Current Plan Status

The development plan is current against the repository worktree on the following implemented
surfaces:

- Sprint `1.1`, Sprint `2.1`, Sprint `3.3`, and Sprint `4.1` reopened container, toolchain,
  lifecycle, and PostgreSQL operator surfaces and are now implemented in code.
- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding repo-root `prodbox-config.dhall` through `dhall-to-json` without materializing
  `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/env/Main.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, repository-root config-path
  resolution, and the built-frontend env proof for the direct-Dhall settings surface.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- The public `config setup` and public `aws ...` surfaces use prompt-driven temporary elevated AWS
  credentials, while stored `aws_admin_for_test_simulation.*` remains reserved for test-suite
  simulation of that prompt input, with the native IAM validation harness as the only supported
  runtime consumer.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  repository-root credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every Haskell-build Dockerfile
  stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and does not
  create symlinked Haskell tool shims; the permitted `docker/nginx-oidc.Dockerfile` Alpine-based
  exception remains unchanged.
- The local lifecycle is Haskell-owned and Harbor-first: Harbor plus Harbor's storage backend may
  bootstrap from public registries, after which required public images and custom images are
  present in Harbor before later Helm deployments proceed.
- The Harbor mirror path retries alternate configured upstreams when publication fails after
  manifest inspection.
- The Haskell-owned lifecycle now retries transient upstream Helm fetch failures during
  `helm repo update` and `helm upgrade --install`, so clean-room restore does not fail terminally
  on intermittent upstream `5xx` or timeout errors.
- The chart-platform end state is Haskell-owned and renders namespace-local
  Percona-operator-backed Patroni PostgreSQL HA through `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs`, with exactly three replicas, synchronous replication,
  deterministic retained PV bindings, retained secret state, and no embedded chart-local
  PostgreSQL subcharts.
- The public `prodbox pulumi ...` surface is limited to the AWS validation stacks under
  `pulumi/aws-eks/` and `pulumi/aws-test/`. Non-secret validation inputs are synchronized through
  stack config, while AWS provider credentials stay only in `prodbox-config.dhall` and the
  Haskell-owned subprocess environment.
- The current gateway runtime surface is Haskell-owned and code-backed in `src/Prodbox/Gateway.hs`,
  `src/Prodbox/Gateway/Daemon.hs`, and `src/Prodbox/Gateway/Types.hs`: config generation,
  heartbeat recording, in-memory ownership projection, DNS-write gating, REST status, and HMAC
  event signing are implemented there today.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox pulumi ...` command
  family.
- The earlier unsupported root `Pulumi.yaml` and `Pulumi.home.yaml` residue for the retired
  local-cluster `pulumi/home` path is removed.
- The canonical validation surfaces are `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, the named native validation flows in
  `src/Prodbox/TestValidation.hs`, and the aggregate reruns `./.build/prodbox test integration all`
  plus `./.build/prodbox test all`.
- Environment-dependent AWS IAM, Route 53, public-edge, EKS, and HA-RKE2 proof are implemented
  as named `prodbox` validation commands rather than asserted here as a fresh run result.
- The legacy ledger has no pending items on the supported path.

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
5. `aws_admin_for_test_simulation.*` may be stored in `prodbox-config.dhall` only as the
   test-suite simulation of the ephemeral elevated credential prompt. The native IAM validation
   harness is the only supported runtime consumer of that section, and no supported non-test
   command or runtime helper may read or use it.
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
16. Pulumi remains part of the supported architecture for true IaC and AWS validation resources.
   The public `prodbox pulumi ...` surface stays limited to those stacks, while local-cluster
   lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
   `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
17. No supported Pulumi program depends on Python.
18. The strongest clean-room rerun passes from full local delete through final AWS teardown using
   the Haskell stack.
19. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
   cleanup.
20. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
