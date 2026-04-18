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

As of April 18, 2026, the repository is closed again on the Haskell-only handoff target. The
repository now contains:

- one compiled Haskell `prodbox` binary owning the full supported command surface
- one Haskell-owned CLI, config, lifecycle, Pulumi, gateway, chart, AWS, and test surface
- one direct `Dhall -> Haskell types` config contract rooted at `prodbox-config.dhall`
- one native validation harness for the named real-world proof surfaces behind
  `prodbox test integration ...`
- one YAML-Pulumi infrastructure path with no Python runtime dependency
- zero Python implementation, Python toolchain, or Python bridge artifacts in the repository

Phase `1` reopened on April 18, 2026 after a documentation and harness audit. That reopened work
is now closed: the operator-facing host artifact contract is enforced at `./.build/prodbox`,
`test/integration/cli/Main.hs` and `test/integration/env/Main.hs` pass, the named validation
payloads behind `prodbox test integration ...` are executable native Haskell validation flows,
`prodbox config compile` is removed, `prodbox-config.json` is no longer part of the supported
repository contract, and the governed docs plus root guidance docs listed in Sprint `1.2` are
aligned with the Haskell-only repository state.

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

**Status interpretation**: all phases are closed again. The repository is Haskell-only, the
reopened Phase `1` validation and documentation work is complete, and later phases `2-7` remain
done on their owned runtime or zero-Python removal surfaces.

**Canonical target architecture**: one Haskell `prodbox` CLI, one repository-root
`prodbox-config.dhall` decoded directly into Haskell types with `prodbox-config-types.dhall` as
the shared schema and no supported `prodbox-config.json` artifact, one supported host runtime
(`Ubuntu 24.04 LTS` with systemd), one host build root `.build/` with the operator-facing binary
at `.build/prodbox` (runnable as `./.build/prodbox`), produced by the canonical
`cabal build --builddir=.build exe:prodbox` invocation plus a copy step, one container build root
`/opt/build` configured explicitly in the Dockerfile, one local RKE2 lifecycle owned by Haskell,
one Pulumi integration path retained without Python Pulumi programs, one in-cluster gateway
runtime, one Haskell chart platform, one explicit cleanup/removal ledger, and one destructive
clean-room rerun that closes with no supported-path Python artifacts left in the repository.

## Current Plan Status

As of April 18, 2026, the development plan is fully closed again:

- The repository is Haskell-only. All Python source under `src/prodbox/`, `tests/`, and
  `typings/`, plus Python packaging (`pyproject.toml`, `poetry.toml`, `.python-version`) and
  bridge modules (`Backend/Python.hs`, `PythonEnv.hs`), remain removed.
- All Pulumi programs are YAML-based: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, and
  `pulumi/aws-test/Main.yaml`. The root `Pulumi.yaml` uses `runtime: yaml`.
- `CheckCode.hs` owns `prodbox check-code` and runs `cabal build --builddir=.build all`, then
  syncs the operator-facing binary to `.build/prodbox`.
- `TestRunner.hs` owns `prodbox test ...`, runs the Haskell suites via `cabal test`, and executes
  the named real-world validation flows through `src/Prodbox/TestValidation.hs`.
- The supported config contract is direct `Dhall -> Haskell types`: `src/Prodbox/Settings.hs`
  decodes and validates `prodbox-config.dhall` without materializing `prodbox-config.json`, and
  the public `prodbox config` surface is `setup|show|validate`.
- The local closure proofs for the reopened Sprint `1.2` work pass on the April 18, 2026 worktree:
  `cabal build --builddir=.build exe:prodbox`,
  `cabal test --builddir=.build test:prodbox-unit test:prodbox-integration-cli test:prodbox-integration-env`,
  `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`,
  and `./.build/prodbox check-code`.
- The named integration suites `aws-iam`, `dns-aws`, `aws-eks`, `pulumi`, `ha-rke2-aws`,
  `gateway-daemon`, `gateway-pods`, `gateway-partition`, `charts-platform`, `charts-storage`,
  `charts-vscode`, `public-dns`, and `lifecycle` now run executable native Haskell validation
  flows instead of pending-placeholder failures.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is empty in `Pending Removal`.
- Root guidance docs and the governed docs listed in Sprint `1.2` now describe the Haskell-only
  repository and current validation harness.

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
5. Container-side build artifacts live under `/opt/build`, enforced explicitly by the Dockerfile.
6. Pulumi remains part of the supported architecture, but no supported Pulumi program depends on
   Python.
7. The strongest clean-room rerun passes from full local delete through final AWS teardown using
   the Haskell stack.
8. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is empty in `Pending Removal`.
9. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
