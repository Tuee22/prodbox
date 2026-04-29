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

The target architecture has expanded. Earlier closed phases are reopened on the self-managed public
edge migration to MetalLB + Envoy Gateway + Keycloak:

- Phase `1` is reopened on local lifecycle, image-delivery, and config-foundation work required by
  the Gateway API edge.
- Phase `3` is reopened on chart-delivery and browser-auth work required to remove `vscode-nginx`.
- Phase `5` is reopened on public-edge diagnostics and external proof required to replace the
  Traefik/`Ingress` readiness model.

Phases `0`, `2`, `4`, `6`, and `7` remain closed on their owned surfaces. In particular:

- `src/Prodbox/CheckCode.hs` still closes on the repository-owned workflow and doctrine gate.
- `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, and `src/Prodbox/Gateway/Types.hs`
  remain closed on the implemented Haskell gateway-daemon `/v1/state` surface; that runtime is
  distinct from the Kubernetes Gateway API public edge.
- The Haskell-only CLI, AWS validation harness, direct-Dhall config contract, Harbor-first
  lifecycle, Percona PostgreSQL doctrine, and zero-Python cleanup remain closed on their delivered
  repository surfaces.

The current worktree still closes on the implemented Haskell-only baseline described by this plan:

- `src/Prodbox/CheckCode.hs` enforces the repository-owned workflow and git-hook policy described
  by `documents/engineering/code_quality.md`, then runs Fourmolu, HLint, warning-clean Cabal
  builds, and the operator-binary sync step.
- `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, and `src/Prodbox/Gateway/Types.hs`
  close on the implemented HTTP `/v1/state` observability payload, the documented status fields
  including `event_hashes` and `heartbeat_age_seconds`, and the Orders-backed interval-validation
  path enforced during config and status handling.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`,
  `src/Prodbox/EffectInterpreter.hs`, and `src/Prodbox/Infra/MinioBackend.hs` keep the aggregate
  AWS-backed validation flow behind the visible local runbook and repair the repo-backed MinIO
  Pulumi backend before validation continues.
- `docker/prodbox.Dockerfile` and `docker/gateway.Dockerfile` install `ghcup` in-image and pin
  GHC `9.14.1`, while `src/Prodbox/CLI/Rke2.hs` no longer uses the lifecycle-managed
  `haskell-toolchain` BuildKit context.
- `cabal.project` pins `ghc-9.14.1`, `prodbox.cabal` carries the package-bound updates required
  by that toolchain, and the chart plus lifecycle surfaces use the Percona operator rather than
  the retired Zalando operator assumptions.

The supported architecture is still Haskell-only. The public `prodbox pulumi ...` surface is
limited to the AWS validation stacks under `pulumi/aws-eks/` and `pulumi/aws-test/`, while
local-cluster lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned
by `src/Prodbox/CLI/Rke2.hs`. The chart-platform baseline remains namespace-local
Percona-operator-backed Patroni PostgreSQL HA for Helm-managed application data, and the Harbor
bootstrap exception remains limited to Harbor plus Harbor's storage backend before later Helm
deployments switch to Harbor-backed image refs.

The reopened target doctrine for the self-managed public edge is now:

- MetalLB exposes the edge `LoadBalancer` IP on the local cluster.
- Envoy Gateway and Kubernetes Gateway API replace Traefik and `Ingress` as the target public edge.
- Keycloak remains the identity provider.
- Envoy Gateway `SecurityPolicy` replaces the app-local `vscode-nginx` browser auth proxy.
- Redis is optional future shared realtime state only; it is not part of Envoy JWT validation.

The canonical validation contract is expressed through the `prodbox` commands documented by this
plan: `./.build/prodbox check-code`, `./.build/prodbox test unit`,
`./.build/prodbox test integration cli`, `./.build/prodbox test integration env`, the named
native validations behind `./.build/prodbox test integration ...`, and the clean-room rerun owned
by Phase `6`. Environment-dependent AWS and public-edge proof remain attached to those commands
rather than recorded here as a fresh execution log.

The canonical closure gates remain the `prodbox` surfaces defined by this plan: the `.build`
artifact contract, `prodbox check-code`, the built-frontend `cli` and `env` suites, the named
native validation flows behind `prodbox test integration ...`, and the destructive clean-room
rerun owned by Phase `6`. Validation details live in the phase documents and the component
inventory rather than in an ad hoc log here.

The current tracked worktree contains:

- one Haskell codebase that builds the supported `prodbox` binary and owns the full supported
  command surface
- one operator-facing build-artifact contract that produces `.build/prodbox` from the canonical
  Cabal build-plus-copy flow
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
- one repo-local retained validation-state contract rooted at `.prodbox-state/`, where generated
  runs write AWS stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, the HA-RKE2 validation SSH key under
  `.prodbox-state/aws-test/`, and namespace-local chart state under
  `.prodbox-state/<namespace>/`
- one current Traefik plus `Ingress` public edge and one app-local `vscode-nginx` auth proxy as
  compatibility residue pending removal
- zero Python implementation, Python toolchain, or Python bridge artifacts in the repository
- one cleanup ledger that is now reopened on the Envoy Gateway migration residue while remaining
  clear on Python-removal work

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
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | 🔄 Active | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ Done | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | 🔄 Active | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ Done | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | 🔄 Active | [phase-5-public-host-validation.md](phase-5-public-host-validation.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ Done | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | ✅ Done | [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md) |

**Status interpretation**: the Haskell-only rewrite remains closed on Phases `0`, `2`, `4`, `6`,
and `7`, while the self-managed public-edge expansion reopens Phases `1`, `3`, and `5` until the
Envoy Gateway target replaces the current Traefik/`Ingress`/`vscode-nginx` baseline.

## Current Plan Status

The development plan is current against the repository worktree on the following implemented
surfaces and reopened target gaps:

- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding repo-root `prodbox-config.dhall` through `dhall-to-json` without materializing
  `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/env/Main.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, repository-root config-path
  resolution, and the built-frontend env proof for the direct-Dhall settings surface.
- `src/Prodbox/CheckCode.hs` now enforces the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`: it fails on repository-owned workflow or git-hook
  surfaces before it runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary
  sync step, while excluding generated or retained runtime roots such as `.build/`,
  `dist-newstyle/`, `.prodbox-state/`, and `.data/` from the repo-owned policy scan.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- The public `config setup` and public `aws ...` surfaces use prompt-driven temporary elevated AWS
  credentials, while stored `aws_admin_for_test_simulation.*` remains reserved for test-suite
  simulation of that prompt input, with the native IAM validation harness as the only supported
  runtime consumer.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, `prodbox test integration all`, and
  `prodbox test all` through one shared suite-level IAM harness that provisions temporary
  operational `aws.*` before prerequisite-driven AWS validation begins and clears those
  credentials again before the suite returns.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `rke2 install`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The shared IAM harness deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, materializes operational `aws.*` only from
  `aws_admin_for_test_simulation.*`, and clears `aws.*` from `prodbox-config.dhall` before
  returning even on later prerequisite failure.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  repository-root credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every Haskell-build Dockerfile
  stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and does not
  create symlinked Haskell tool shims. The current `docker/nginx-oidc.Dockerfile` remains
  migration residue owned by the reopened Envoy edge work.
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
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS validation stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`.
- The current gateway runtime surface is Haskell-owned and code-backed in `src/Prodbox/Gateway.hs`,
  `src/Prodbox/Gateway/Daemon.hs`, and `src/Prodbox/Gateway/Types.hs`: config generation,
  heartbeat recording, in-memory ownership projection, DNS-write gating, the HTTP `/v1/state`
  observability payload, HMAC event signing, and Orders-backed gateway-interval validation are all
  implemented there today. The parsed certificate, key, CA, and socket fields remain part of the
  config or Orders model, but the closed repository surface does not materialize peer transport
  from them today.
- `src/Prodbox/Tla.hs` still owns `prodbox tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox pulumi ...` command
  family.
- The current self-managed public edge still installs Traefik, renders `Ingress`, and fronts
  browser auth through `vscode-nginx`; the target doctrine now reopens those surfaces toward
  MetalLB + Envoy Gateway + Gateway API + Keycloak edge enforcement.
- The current repository still carries `docker/nginx-oidc.Dockerfile`,
  `src/Prodbox/Host.hs` Traefik/`Ingress` public-edge classification, and the `charts/vscode`
  `Ingress` plus `vscode-nginx` path as pending-removal compatibility surfaces.
- The earlier unsupported root `Pulumi.yaml` and `Pulumi.home.yaml` residue for the retired
  local-cluster `pulumi/home` path is removed.
- The canonical validation surfaces are `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, the named native validation flows in
  `src/Prodbox/TestValidation.hs`, and the aggregate reruns `./.build/prodbox test integration all`
  plus `./.build/prodbox test all`.
- The aggregate rerun contract is owned by the shared suite plan behind
  `./.build/prodbox test integration all` and `./.build/prodbox test all`, including AWS IAM,
  Route 53, public-edge, EKS, HA-RKE2, destructive lifecycle, and post-test restore.
- The legacy ledger has reopened non-Python pending items for the Envoy Gateway migration while
  remaining closed on Python-removal residue.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture and the Envoy
   Gateway target rather than the retired Python architecture or a Traefik end state.
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
6. `prodbox test integration aws-iam`, `prodbox test integration all`, and `prodbox test all`
   share one joint idempotent IAM validation harness that deletes any pre-existing dedicated
   `prodbox` IAM user and all of that user's access keys before provisioning, uses any
   pre-existing `aws.*` credentials only to discover and delete the IAM user associated with those
   credentials, materializes operational `aws.*` only from `aws_admin_for_test_simulation.*` to
   simulate the interactive public CLI workflow, and clears operational `aws.*` from
   `prodbox-config.dhall` before returning so no test-created dedicated IAM user or key survives.
7. The operator-facing binary lives at `.build/prodbox` (runnable as `./.build/prodbox`),
   produced by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy
   step.
8. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
9. Every repository-owned Haskell-build Dockerfile is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims; no
   supported browser-facing auth path depends on a permanent `docker/nginx-oidc.Dockerfile`
   exception.
10. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
    upgraded for GHC `9.14.1`, including any required cabal-bound changes and full canonical
    validation reruns on that toolchain.
11. `prodbox check-code` enforces the governed doctrine-alignment contract described by
    `documents/engineering/code_quality.md`, not only formatter, linter, build, and binary-sync
    checks.
12. The Haskell distributed gateway runtime, `gateway status` client path, and daemon config
    validation close on the implemented HTTP `/v1/state` observability payload, the Orders-backed
    gateway-interval relationships enforced by `src/Prodbox/Gateway/Types.hs`, and the current
    correspondence notes in `documents/engineering/tla_modelling_assumptions.md`.
13. The self-managed public edge uses MetalLB, Envoy Gateway, Kubernetes Gateway API, and
    cert-manager rather than Traefik plus `Ingress`.
14. Public browser-facing auth for supported apps is enforced at the Envoy edge with Keycloak as
    the identity provider; no supported `vscode` path depends on `vscode-nginx`.
15. The supported public-host doctrine prefers dedicated identity and app hostnames rather than the
    shared-host `/auth` model, while preserving explicit per-FQDN Route 53 ownership and rejecting
    wildcard public DNS.
16. `prodbox host public-edge`, `prodbox test integration charts-vscode`, and
    `prodbox test integration public-dns` close on Gateway, `HTTPRoute`, certificate, and Route 53
    state rather than `IngressClass` or `Ingress` state.
17. Redis is optional app-level shared state only for future realtime or rate-limit workloads; it
    is not part of Envoy JWT validation.
18. Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
    storage backend during bootstrap.
19. Every later supported Helm deployment obtains its images from Harbor.
20. `prodbox` idempotently ensures required public images and all custom images are present in
    Harbor after Harbor bootstrap and before those later deployments.
21. Both `amd64` and `arm64` image variants or manifests are built, loaded, mirrored, or fetched
    irrespective of the architecture of the machine running `prodbox`.
22. Mixed-arch clusters are supported on the canonical lifecycle and chart-delivery path.
23. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
    cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
    synchronous replication, and no embedded chart-local PostgreSQL subchart.
24. Pulumi remains part of the supported architecture for true IaC and AWS validation resources.
    The public `prodbox pulumi ...` surface stays limited to those stacks, while local-cluster
    lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
    `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
25. No supported Pulumi program depends on Python.
26. The strongest clean-room rerun passes from full local delete through final AWS teardown using
    the Haskell stack.
27. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
    cleanup.
28. The repository has no supported-path Python implementation or Python toolchain ownership
    artifacts left.
