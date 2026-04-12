# File: DEVELOPMENT_PLAN/README.md
# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md), [../documents/engineering/README.md](../documents/engineering/README.md), [../documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md), [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md), [../documents/engineering/dependency_management.md](../documents/engineering/dependency_management.md), [../documents/engineering/distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md), [../documents/engineering/helm_chart_platform_doctrine.md](../documents/engineering/helm_chart_platform_doctrine.md), [../documents/engineering/unit_testing_policy.md](../documents/engineering/unit_testing_policy.md)

> **Purpose**: Provide the single execution-ordered development plan for prodbox, including honest
> sprint status, validation gates, blocker tracking, and legacy-path removal.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan, including phase structure, sprint formatting, documentation requirements, and
the cleanup/removal ledger.

## Document Index

| Document | Purpose |
|----------|---------|
| [development_plan_standards.md](development_plan_standards.md) | Conventions for maintaining the development plan |
| [system-components.md](system-components.md) | Authoritative component inventory |
| [00-overview.md](00-overview.md) | Architecture overview, constraints, current repository state, and rerun blockers |
| [phase-0-planning-documentation.md](phase-0-planning-documentation.md) | Phase 0: Planning and documentation topology |
| [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) | Phase 1: Runtime, CLI, and AWS validation foundations |
| [phase-2-gateway-dns.md](phase-2-gateway-dns.md) | Phase 2: Distributed gateway runtime and DNS ownership |
| [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) | Phase 3: Chart platform and cluster-backed `vscode` delivery |
| [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) | Phase 4: Lifecycle hardening and canonical-path cleanup |
| [phase-5-public-host-validation.md](phase-5-public-host-validation.md) | Phase 5: Public hostname closure and authoritative external proof |
| [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) | Phase 6: Final clean-room rerun and zero-legacy handoff |
| [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) | Comprehensive ledger of compatibility, duplicate-path, and cleanup removals |

## Sprint Status

### Status Vocabulary

| Status | Meaning | Emoji |
|--------|---------|-------|
| **Done** | Deliverables implemented, validation closed on the supported path, docs aligned, and no sprint-owned work remains | ✅ |
| **Active** | Partially implemented or being closed now; remaining work is explicitly listed | 🔄 |
| **Blocked** | The sprint cannot close until the listed external prerequisite, environment dependency, or prior sprint closes | ⏸️ |
| **Planned** | Ready to start; dependencies are already satisfied and no unmet blocker remains | 📋 |

**Rules:**

- Every sprint has exactly one status.
- `Blocked` sprints must list `Blocked by`.
- `Active` sprints must list `Remaining Work`.
- `Planned` sprints must not list unmet blockers.
- Compatibility helpers, duplicate paths, and deprecated surfaces are tracked in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), not hidden inside phase prose.

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Deliverables are implemented in the repository worktree.
2. The sprint's validation commands pass through the canonical `poetry run prodbox ...` path.
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup/removal work is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned `Remaining Work` or blocker remains.

### Phase Overview

| Phase | Name | Status | Document |
|-------|------|--------|----------|
| 0 | Planning and Documentation Topology | ✅ Done | [phase-0-planning-documentation.md](phase-0-planning-documentation.md) |
| 1 | Runtime, CLI, and AWS Validation Foundations | ✅ Done | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Distributed Gateway Runtime and DNS Ownership | ✅ Done | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Chart Platform and Cluster-Backed `vscode` Delivery | ✅ Done | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening and Canonical-Path Cleanup | ✅ Done | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Public Hostname Closure and Authoritative External Proof | ✅ Done | [phase-5-public-host-validation.md](phase-5-public-host-validation.md) |
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | 🔄 Active | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |

**Canonical architecture**: one supported `prodbox` CLI surface, one repository-root Dhall
config auto-compiled idempotently to JSON when supported commands load settings, one
in-cluster always-on gateway Route 53 write path through
`dns_write_gate` managed by `prodbox charts` (no host-side daemons), explicit per-subdomain
Route 53 records only, one coherent `MetalLB -> Traefik -> vscode-nginx` public-host stack, one
cluster-backed `prodbox charts` delivery path for `vscode`, one named validation command per
major surface, one explicit removal ledger for anything still scheduled to disappear, one
cluster-wide StorageClass named `manual`, one explicit PV pre-creation model, one Helm-only
service deployment path, explicit chart-owned replica counts that keep single-writer retained-state services single-replica, and subprocess credential isolation with no `os.environ` inheritance.

### Sprint Details

| Sprint | Status | Blocked by | Remaining Work | Implementation |
|--------|--------|------------|----------------|----------------|
| 0.1 Planning and Documentation Topology Baseline | ✅ Done | - | - | `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`, `documents/engineering/README.md` |
| 1.1 Runtime, CLI, and Test-Command Foundations | ✅ Done | - | - | `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `tests/integration/test_cli_commands.py`, `tests/integration/test_cli_env.py` |
| 1.2 AWS Auth Doctrine and Real-System Validation Foundation | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/test_aws_foundation_real.py`, `tests/integration/test_aws_eks_real.py`, `tests/integration/test_dns_route53_aws.py`, `tests/integration/test_pulumi_real.py` |
| 2.1 Distributed Gateway Runtime, Formal Verification, and DNS-Write Capability | ✅ Done | - | - | `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/tla.py`, `src/prodbox/tla_check.py`, `tests/integration/test_gateway_daemon_k8s.py`, `tests/integration/test_gateway_k8s_pods.py` |
| 3.1 Chart Platform and Deterministic Retained Storage | ✅ Done | - | - | `src/prodbox/cli/charts.py`, `src/prodbox/lib/chart_platform.py`, `tests/integration/test_charts_storage.py`, `tests/integration/test_charts_platform.py` |
| 3.2 `vscode` Stack and Canonical Cluster Auth Path | ✅ Done | - | - | `src/prodbox/cli/charts.py`, `tests/integration/test_charts_platform.py`, `tests/integration/test_charts_vscode.py`, `documents/engineering/helm_chart_platform_doctrine.md` |
| 4.1 `rke2 cleanup` Hardening and Lifecycle Regression Closure | ✅ Done | - | - | `src/prodbox/cli/rke2.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_prodbox_lifecycle.py` |
| 4.2 Canonical-Path Cleanup and Legacy Removal | ✅ Done | - | - | `src/prodbox/cli/gateway.py`, `src/prodbox/settings.py`, `src/prodbox/cli/summary.py`, `src/prodbox/lib/lint/` |
| 4.3 Adaptive Edge Infrastructure Reconcile and Ingress Ownership | ✅ Done | - | - | Infra modules, CLI modules, `tests/integration/test_charts_platform.py` |
| 4.4 In-Cluster Gateway Daemon and DNS Continuity | ✅ Done | - | - | `charts/gateway/`, `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/lib/chart_platform.py`, `tests/integration/test_gateway_k8s_pods.py`, `tests/integration/test_gateway_partition.py` |
| 4.5 Storage Path Migration, Single StorageClass, and HA Doctrine | ✅ Done | - | - | `src/prodbox/lib/chart_platform.py`, `src/prodbox/lib/prodbox_k8s.py`, `src/prodbox/settings.py`, chart templates and values |
| 4.6 Configuration Simplification and K8s Secret Injection | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/lib/chart_platform.py`, `src/prodbox/cli/dag_builders.py`, infra modules |
| 4.7 Dhall Config Schema, Bootstrap, and JSON Loading | ✅ Done | - | - | `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, CLI modules |
| 4.8 Settings Migration and AWS Auth Removal | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/lib/aws_auth.py` (deletion), `src/prodbox/cli/interpreter.py`, `tests/conftest.py` |
| 4.9 Subprocess Credential Isolation and Legacy Cleanup | ✅ Done | - | - | `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/env.py` (removal) |
| 4.10 AWS Fixture Leak Prevention | ✅ Done | - | - | `tests/integration/conftest.py`, `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/main.py`, `tests/integration/sweep_runner.py` |
| 4.11 Final Subprocess Env Isolation and Settings-Only Config Access | ✅ Done | - | - | `src/prodbox/cli/check_code.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/interpreter.py` |
| 4.12 Host Gateway Service Removal | ✅ Done | - | - | `src/prodbox/cli/gateway.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, host filesystem, `documents/engineering/*`, `DEVELOPMENT_PLAN/*` |
| 4.13 Per-Test AWS Fixture Hygiene and Resource Tagging | ✅ Done | - | - | `tests/integration/aws_helpers.py`, `tests/integration/conftest.py`, `tests/integration/test_aws_foundation_real.py`, `tests/integration/test_aws_eks_real.py`, `tests/integration/test_dns_route53_aws.py`, `tests/integration/test_pulumi_real.py`, `src/prodbox/cli/aws_cmd.py` |
| 5.1 Public Hostname Closure and Authoritative External Proof | ✅ Done | - | - | `prodbox-config.dhall`, `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/infra/cluster_issuer.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/test_public_dns_delegation.py` |
| 6.1 Final Clean-Room Validation Rerun and Zero-Legacy Handoff | ✅ Done | - | - | `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/infra/cert_manager.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/metallb.py`, `tests/unit/test_infra_program.py`, `tests/unit/test_test_cmd.py` |
| 6.2 Clean-Cluster Aggregate Bootstrap and Zero-AWS-Residue Closure | 🔄 Active | - | Final handoff still needs one fresh clean-room aggregate rerun from a repo state with no precompiled `prodbox-config.json`, now that canonical settings loads auto-compile Dhall idempotently when the compiled artifact is missing or stale | `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `tests/unit/test_settings.py`, `tests/integration/test_cli_env.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/aws_helpers.py` |

## Current Plan Status

As of April 12, 2026: **Phase 6 remains active.**
The clean-cluster public-edge/bootstrap blockers are closed, and a full
`poetry run prodbox rke2 cleanup --yes` -> `poetry run prodbox test all` rerun already succeeded
on April 12, 2026 with the post-aggregate AWS sweep reporting no fixture-owned Route 53, S3, VPC,
EKS, or IAM resources. A second rerun at 17:31 on April 12, 2026 exposed one remaining clean-room
handoff gap: supported commands still assumed a precompiled `prodbox-config.json` after
`prodbox-config.dhall` changed or the compiled artifact was absent.

Sprint 6.2 now owns that final repo-state closure requirement. The canonical settings load path in
`Settings.from_config_json()` auto-compiles `prodbox-config.dhall` to `prodbox-config.json`
whenever the repository-root JSON artifact is missing or older than the Dhall source/schema, so
commands such as `prodbox config show`, `prodbox config validate`, `prodbox pulumi ...`, and the
aggregate `prodbox test all` restore path no longer depend on a manually prepared compiled config.
The remaining work is one fresh end-to-end clean-room rerun from a state where no
`prodbox-config.json` exists before handoff is re-closed.

Current-environment validation snapshot (April 12, 2026):

- `poetry run prodbox rke2 cleanup --yes` followed by `poetry run prodbox test all` completed
  successfully on April 12, 2026; the aggregate postflight restored the supported runtime,
  `prodbox host public-edge` ended at `CLASSIFICATION=ready-for-external-proof`, and the final
  `prodbox aws sweep-fixtures` run reported no fixture-owned AWS resources remaining.
- A second `poetry run prodbox test all` run at 17:31 on April 12, 2026 failed in `Phase 1.6/2`
  with `[Errno 2] No such file or directory: '/home/matthewnowak/prodbox/prodbox-config.json'`
  after `prodbox-config.dhall` changed and the compiled JSON artifact was absent.
- `src/prodbox/settings.py` now auto-compiles the canonical repository Dhall config whenever the
  compiled JSON is missing or stale, and `tests/unit/test_settings.py` plus
  `tests/integration/test_cli_env.py` now cover that command-surface behavior.
- `poetry run prodbox config show` and `poetry run prodbox config validate` both passed on
  April 12, 2026 after the repository-root `prodbox-config.json` artifact was removed; each
  command regenerated the JSON artifact automatically from `prodbox-config.dhall`.
- `poetry run prodbox pulumi refresh` also passed on April 12, 2026 after the repository-root
  `prodbox-config.json` artifact was removed, proving that the Phase 1.6 restore-class command
  surface no longer depends on a manually prepared compiled config.
- `poetry run prodbox check-code` passed on April 12, 2026 after the command and plan updates.
- The final Phase 6 closure gate remains one new aggregate rerun from a repository state without a
  precompiled `prodbox-config.json`, so the handoff proof covers both a clean RKE2 cluster and a
  clean repo config state.

## Exit Definition

This plan is done only when all of the following are true:

1. Sprint 4.1 remains closed without retry-based cleanup settling in the lifecycle suite.
2. Sprint 4.2 closes with one canonical runtime path, one canonical CLI path, and one canonical
   automated validation path per major surface.
3. Sprint 4.3 closes with one coherent public-edge ownership model: adaptive MetalLB addressing,
   Traefik as the supported cluster-edge controller, cert-manager bootstrap ownership, and no
   competing public ingress path.
4. Sprint 4.4 closes with the gateway daemon running as an in-cluster Kubernetes workload
   under `prodbox charts`, with leader election guaranteeing exactly one Route 53 writer,
   partition tolerance proven by a named integration suite, and explicit public subdomain
   Route 53 records kept current through `dns_write_gate`.
5. Sprint 4.5 is closed with one StorageClass named `manual`, the 5-segment `.data/` path scheme,
   explicit replica counts aligned to each chart's storage semantics, and no residual 4-segment
   path references outside completed-sprint history.
6. Sprint 4.6 is closed with cluster-internal secrets auto-generated and persisted in `.data/`,
   IP addressing always auto-discovered, and `KUBECONFIG`/`PULUMI_STACK` removed from settings.
7. Sprint 4.7 is closed with `prodbox-config.dhall` as the single config source, explicit
   `prodbox config compile` support, and canonical settings loads auto-compiling JSON when the
   compiled artifact is missing or stale; `prodbox config init` still bootstraps from system
   state.
8. Sprint 4.8 is closed with `Settings` loading from JSON (not `.env`), `pydantic-settings`
   removed, `aws_auth.py` deleted, and all AWS credential access flowing through `Settings`.
9. Sprint 4.9 is closed with subprocess environments built explicitly from configuration (no
   `os.environ` inheritance), `prodbox env` removed, and all `.env` code deleted.
10. Sprint 4.10 is closed with a session-scoped pre-test janitor sweep, a `prodbox aws
    sweep-fixtures` CLI command, and hourly cron supervision for AWS fixture leak prevention.
11. Sprint 4.11 is closed with all subprocess env builders using explicit allowlists (no
    `os.environ` inheritance) and all config access flowing through `Settings` (no env fallbacks).
12. Sprint 4.12 is closed with `prodbox-gateway.service` uninstalled from the supported host,
    `prodbox gateway install-service` removed from the CLI surface, and all "host supervisor"
    language purged from the plan and doctrine docs.
13. Sprint 4.13 closes with every AWS-mutating integration test beginning from scope-owned
    stale-resource search/removal, every taggable fixture-owned AWS resource carrying the
    canonical ownership/expiry/safe-delete tags, setup helpers rolling back partial AWS creation
    before the fixture yields, and janitor coverage validated across Route 53, S3, VPC, EKS, and
    IAM.
14. Sprint 5.1 closes with authoritative public DNS delegation proof plus live TLS and auth-wall
    verification for `vscode.resolvefintech.com`.
15. Sprint 6.1 reruns the final doctrine-aligned validation set from canonical CLI entrypoints and
    keeps the legacy ledger empty at the point of handoff.
16. Sprint 6.2 closes with `poetry run prodbox rke2 cleanup --yes` followed by the canonical
    aggregate rerun restoring the full public-edge stack without manual Pulumi, Helm, host
    resolver, or config-compilation intervention; `prodbox host public-edge` must render a
    deterministic report even when the edge stack is absent or partially torn down, the rerun must
    succeed without a preexisting repository-root `prodbox-config.json`, and the restored path must
    end at `CLASSIFICATION=ready-for-external-proof`.
17. Sprint 6.2 also closes with the authoritative public-host proof path using public DNS only
    (no `/etc/hosts` override for `vscode.resolvefintech.com`) and with an immediate
    post-aggregate `poetry run prodbox aws sweep-fixtures` audit proving that no fixture-owned
    Route 53, S3, VPC, EKS, or IAM resources remain.
18. No document under `documents/` carries a competing sprint narrative or completion-status track.
19. The remaining legacy inventory is empty.

## Related Documents

- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [../README.md](../README.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
- [../documents/documentation_standards.md](../documents/documentation_standards.md)
