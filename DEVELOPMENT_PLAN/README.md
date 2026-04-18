# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md), [../documents/engineering/README.md](../documents/engineering/README.md)

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and Python-removal ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Completed Rewrite

As of April 17, 2026, the Haskell rewrite is complete. The repository now contains:

- one compiled Haskell `prodbox` binary owning the full supported command surface
- one Haskell-owned CLI, test, lifecycle, config, and AWS administration surface
- one Pulumi integration path using YAML Pulumi definitions (no Python dependency)
- zero Python implementation or Python toolchain artifacts

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

**Status interpretation**: All phases are now closed. The Haskell rewrite is complete: all Python
source, Python toolchain, Python bridge modules, and Python Pulumi programs have been removed
from the repository. The codebase is Haskell-only with YAML Pulumi definitions.

**Canonical target architecture**: one Haskell `prodbox` CLI, one repository-root
`prodbox-config.dhall`, one supported host runtime (`Ubuntu 24.04 LTS` with systemd), one host
build root `.build/` owned by the canonical `cabal build --builddir=.build exe:prodbox`
invocation, one container build root
`/opt/build` configured explicitly in the Dockerfile, one local RKE2 lifecycle owned by Haskell,
one Pulumi integration path retained without Python Pulumi programs, one in-cluster gateway
runtime, one Haskell chart platform, one explicit Python-removal ledger, and one destructive
clean-room rerun that closes with no supported-path Python artifacts left in the repository.

## Current Plan Status

As of April 17, 2026, the Haskell rewrite is complete:

- All phases (0 through 7) are closed. Every sprint across all phases has reached Done status.
- The Python toolchain has been completely removed from the repository. All Python source under
  `src/prodbox/`, `tests/`, and `typings/`, plus Python packaging (`pyproject.toml`, `poetry.toml`,
  `.python-version`), and Python bridge modules (`Backend/Python.hs`, `PythonEnv.hs`) are deleted.
- All Pulumi programs are now YAML-based: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`,
  and `pulumi/aws-test/Main.yaml`. The root `Pulumi.yaml` uses `runtime: yaml`. No Python Pulumi
  dependency remains.
- The gateway Dockerfile (`docker/gateway.Dockerfile`) now builds a Haskell binary using a
  multi-stage build with `haskell:9.6.7` builder and `debian:bookworm-slim` runtime.
- `CheckCode.hs` no longer calls Python guards, ruff, or mypy. It runs
  `cabal build --builddir=.build all`.
- `TestRunner.hs` no longer uses PythonEnv or pytest. It runs Haskell test suites via `cabal test`
  and native CLI orchestration for integration flows.
- `Main.hs` no longer imports `Backend.Python`. The `DelegateToPython` case returns an error
  message.
- All 48 unit tests and 14 CLI integration tests pass on the post-Python-removal codebase.
- The repository is now a Haskell-only codebase with one compiled `prodbox` binary owning the
  entire supported command surface.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) has an empty `Pending Removal`
  section.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture rather than the
   Python architecture.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   Pulumi orchestration, gateway, chart delivery, validation, and AWS administration.
3. Host-side build artifacts live under `.build/`, enforced explicitly by the canonical
   `cabal build --builddir=.build exe:prodbox` invocation.
4. Container-side build artifacts live under `/opt/build`, enforced explicitly by the Dockerfile.
5. Pulumi remains part of the supported architecture, but no supported Pulumi program depends on
   Python.
6. The strongest clean-room rerun passes from full local delete through final AWS teardown using
   the Haskell stack.
7. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is empty in `Pending Removal`.
8. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
