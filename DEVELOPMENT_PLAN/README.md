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

As of April 20, 2026, the repository is re-closed on the Haskell-only rewrite, including the
container packaging and registry surfaces reopened by the April 18 Docker and Harbor audit. The
repository-root `Dockerfile` is removed,
`docker/prodbox.Dockerfile` and `docker/gateway.Dockerfile` now follow the single-stage
`ubuntu:24.04` doctrine while sourcing GHC and Cabal from a BuildKit-mounted
`haskell:9.6.7-slim` toolchain context, Harbor-only workload sourcing is wired through the
supported chart and Pulumi paths, dual-arch `amd64` plus `arm64` publication or mirror logic is
implemented, and the legacy ledger is empty again.

The temporary host linker blocker is cleared on this host after installing `libncurses-dev`.
`cabal build --builddir=.build exe:prodbox`, `cabal run --builddir=.build exe:prodbox -- check-code`,
`./.build/prodbox check-code`, `./.build/prodbox test unit`,
`./.build/prodbox test integration cli`, `./.build/prodbox test integration env`,
`./.build/prodbox dns check`, `./.build/prodbox test integration gateway-daemon`,
`./.build/prodbox test integration gateway-pods`, `./.build/prodbox test integration charts-platform`,
`./.build/prodbox test integration charts-vscode`, and
`cabal run --builddir=.build exe:prodbox -- test integration lifecycle` now pass. The current
gateway steady-state contract is also updated in the worktree: `app/prodbox/Main.hs` now permits
repo-rootless in-cluster `gateway start|status`, `charts/gateway/` supplies AWS auth through the
`gateway-aws-credentials` secret and probes `/v1/state` over HTTP, `src/Prodbox/CLI/Pulumi.hs`
projects configured ZeroSSL EAB credentials into cert-manager via `externalAccountBinding`, and
the lifecycle image-reconcile path now requires a stable Harbor `/readyz` plus `/v2/` window
before Docker login or image publication begins.
The destructive delete path is also re-closed on a quieter operator contract: `prodbox rke2 delete
--yes` now reports AWS destroy disposition, local substrate cleanup, managed kubeconfig handling,
and preserved roots without streaming raw Pulumi login chatter or successful uninstall-script
trace noise.

The repository now contains:

- one compiled Haskell `prodbox` binary owning the full supported command surface
- one Haskell-owned CLI, config, lifecycle, Pulumi, gateway, chart, AWS, and test surface
- one direct `Dhall -> Haskell types` config contract rooted at `prodbox-config.dhall`
- one native validation harness for the named real-world proof surfaces behind
  `prodbox test integration ...`
- one YAML-Pulumi infrastructure path with no Python runtime dependency
- zero Python implementation, Python toolchain, or Python bridge artifacts in the repository
- one host with the Haskell build and Phase `1` validation gates re-closed after restoring the
  missing ncurses development linker dependency

Sprint `1.2` remains closed on the direct-Dhall config contract, native validation harness, and
doc harmony: the operator-facing host artifact contract is enforced at `./.build/prodbox`, the
named validation payloads behind `prodbox test integration ...` are executable native Haskell
validation flows, `prodbox config compile` is removed, `prodbox-config.json` is no longer part of
the supported repository contract, and the governed docs plus root guidance docs listed in Sprint
`1.2` are aligned with the Haskell-only repository state. Current host reruns of the associated
build and test commands now pass again on this host.

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
container-build doctrine. Phase `2` owns gateway packaging and DNS ownership, Phase `3` owns the
`vscode-nginx` Harbor delivery contract plus supported chart proof, and Phase `4` owns
Harbor-only cluster image sourcing, idempotent public-image population, dual-arch publication,
and mixed-arch cluster support. Phases `1-4` are re-closed on this host after rerunning the named
gateway, chart, and lifecycle validation surfaces. Phases `5-7` remain done on their owned
public-host, zero-Python, and AWS administration surfaces.

**Canonical target architecture**: one Haskell `prodbox` CLI, one repository-root
`prodbox-config.dhall` decoded directly into Haskell types with `prodbox-config-types.dhall` as
the shared schema and no supported `prodbox-config.json` artifact, one supported host runtime
(`Ubuntu 24.04 LTS` with systemd), one host build root `.build/` with the operator-facing binary
at `.build/prodbox` (runnable as `./.build/prodbox`), produced by the canonical
`cabal build --builddir=.build exe:prodbox` invocation plus a copy step, one container build root
`/opt/build` owned only by Dockerfiles under `docker/`, one repository-owned custom-image doctrine
where every custom Dockerfile is single-stage from `ubuntu:24.04` except
`docker/nginx-oidc.Dockerfile`, which may remain based on `nginx:1.25-alpine`, one local RKE2
lifecycle owned by Haskell, one Harbor-first registry pipeline where Harbor is the only workload
permitted to bootstrap directly from Docker Hub and every other cluster deployment pulls from
Harbor, one idempotent Haskell reconcile path that ensures required public images and custom images
are present in Harbor for both `amd64` and `arm64` irrespective of local host architecture, one
mixed-arch cluster support contract, one Pulumi integration path retained without Python Pulumi
programs, one in-cluster gateway runtime, one Haskell chart platform, one explicit cleanup or
removal ledger, and one destructive clean-room rerun that closes with no supported-path Python
artifacts left in the repository.

## Current Plan Status

As of April 20, 2026, the development plan is fully re-closed on the reopened
container-and-registry surfaces:

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
- The supported config contract is direct `Dhall -> Haskell types`: `src/Prodbox/Settings.hs`
  decodes and validates `prodbox-config.dhall` without materializing `prodbox-config.json`, and
  the public `prodbox config` surface is `setup|show|validate`.
- The canonical host-side validation reruns now pass on this host:
  `cabal build --builddir=.build exe:prodbox`,
  `cabal run --builddir=.build exe:prodbox -- check-code`,
  `./.build/prodbox check-code`,
  `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`,
  and `./.build/prodbox test integration env`.
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
  and `pulumi/home/Main.yaml` now enforce Harbor-backed image references for supported workloads,
  explicit required-public-image population, and `amd64` plus `arm64` per-platform publication
  plus manifest reconcile irrespective of local host architecture.
- `src/Prodbox/CLI/Pulumi.hs` now projects configured ZeroSSL EAB credentials into the
  `cert-manager` namespace as `acme-eab-credentials` and wires the supported `ClusterIssuer`
  through `spec.acme.externalAccountBinding` when `acme.eab_*` is set.
- `src/Prodbox/TestRunner.hs` now waits for `prodbox host public-edge` to report
  `CLASSIFICATION=ready-for-external-proof` during supported-runtime bootstrap and postflight, and
  `src/Prodbox/CLI/Rke2.hs` now requires six consecutive successful Harbor `/readyz` plus `/v2/`
  probes before Docker login or image publication continues on a fresh cluster.
- Harbor now bootstraps before MinIO on the supported install path, and MinIO plus the supported
  chart stack obtain their images from Harbor.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is empty in `Pending Removal`
  again.
- The reopened Phase `2-4` validation surfaces are re-closed on this host:
  `./.build/prodbox dns check`, `./.build/prodbox test integration gateway-daemon`,
  `./.build/prodbox test integration gateway-pods`,
  `./.build/prodbox test integration charts-platform`,
  `./.build/prodbox test integration charts-vscode`, and
  `cabal run --builddir=.build exe:prodbox -- test integration lifecycle`.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture rather than the
   Python architecture.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   Pulumi orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from
   `prodbox-config.dhall`, with `prodbox-config-types.dhall` aligned to the decoder and no
   generated `prodbox-config.json` artifact or supported `prodbox config compile` path.
4. The operator-facing binary lives at `.build/prodbox` (runnable as `./.build/prodbox`),
   produced by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy
   step.
5. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
6. Every custom Dockerfile is single-stage from `ubuntu:24.04`, except
   `docker/nginx-oidc.Dockerfile`, which may remain based on `nginx:1.25-alpine`.
7. Harbor is the only service allowed to bootstrap directly from Docker Hub, and every other
   cluster deployment obtains its images from Harbor.
8. `prodbox` idempotently ensures required public images and all custom images are present in
   Harbor before deployment.
9. Both `amd64` and `arm64` image variants or manifests are built, loaded, mirrored, or fetched
   irrespective of the architecture of the machine running `prodbox`.
10. Mixed-arch clusters are supported on the canonical lifecycle and chart-delivery path.
11. Pulumi remains part of the supported architecture, but no supported Pulumi program depends on
   Python.
12. The strongest clean-room rerun passes from full local delete through final AWS teardown using
   the Haskell stack.
13. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is empty in
   `Pending Removal`.
14. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
