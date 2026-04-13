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
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | ✅ Done | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |

**Canonical architecture**: one supported `prodbox` CLI surface, one repository-root Dhall
config auto-compiled idempotently to JSON when supported commands load settings, one supported
host OS (`Ubuntu 24.04 LTS` with systemd), one host-owned
`prodbox rke2 install|delete --yes|status|start|stop|restart|logs` lifecycle for the RKE2
cluster itself, one in-cluster always-on gateway Route 53 write path through `dns_write_gate`
managed by `prodbox charts` (no host-side daemons), explicit per-subdomain Route 53 records only,
one coherent `MetalLB -> Traefik -> vscode-nginx` public-host stack, one cluster-backed
`prodbox charts` delivery path for `vscode`, one named validation command per major surface, one
explicit removal ledger for anything still scheduled to disappear, one cluster-wide StorageClass
named `manual` recreated at cluster install while every other StorageClass is deleted, one
config-declared manual PV host root (default repository `.data/`) reserved purely for PV content,
one repo-local retained chart-state root `.prodbox-state/` for generated secrets and gateway
event keys preserved across cluster delete/reinstall, one explicit PV pre-creation model with
deterministic PVC/PV rebinding across cluster delete/reinstall cycles, one Helm-only service
deployment path, explicit chart-owned replica counts that keep single-writer retained-state services
single-replica, no host-side cron-driven AWS janitor, harness-owned AWS fixture cleanup that
begins every AWS-mutating test by sweeping any pre-existing tagged fixture resources, and
subprocess credential isolation with no `os.environ` inheritance.

### Sprint Details

| Sprint | Status | Blocked by | Remaining Work | Implementation |
|--------|--------|------------|----------------|----------------|
| 0.1 Planning and Documentation Topology Baseline | ✅ Done | - | - | `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`, `documents/engineering/README.md` |
| 1.1 Runtime, CLI, and Test-Command Foundations | ✅ Done | - | - | `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `tests/integration/test_cli_commands.py`, `tests/integration/test_cli_env.py` |
| 1.2 AWS Auth Doctrine and Real-System Validation Foundation | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/test_aws_foundation_real.py`, `tests/integration/test_aws_eks_real.py`, `tests/integration/test_dns_route53_aws.py`, `tests/integration/test_pulumi_real.py` |
| 1.3 Supported Host Gate and Host-Owned RKE2 Cluster Lifecycle | ✅ Done | - | - | `src/prodbox/cli/rke2.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/prerequisite_registry.py`, `src/prodbox/settings.py` |
| 2.1 Distributed Gateway Runtime, Formal Verification, and DNS-Write Capability | ✅ Done | - | - | `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/tla.py`, `src/prodbox/tla_check.py`, `tests/integration/test_gateway_daemon_k8s.py`, `tests/integration/test_gateway_k8s_pods.py` |
| 3.1 Chart Platform and Deterministic Retained Storage | ✅ Done | - | - | `src/prodbox/cli/charts.py`, `src/prodbox/lib/chart_platform.py`, `tests/integration/test_charts_storage.py`, `tests/integration/test_charts_platform.py` |
| 3.2 `vscode` Stack and Canonical Cluster Auth Path | ✅ Done | - | - | `src/prodbox/cli/charts.py`, `tests/integration/test_charts_platform.py`, `tests/integration/test_charts_vscode.py`, `documents/engineering/helm_chart_platform_doctrine.md` |
| 4.1 Legacy Cleanup Hardening and Lifecycle Regression Closure | ✅ Done | - | - | `src/prodbox/cli/rke2.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_prodbox_lifecycle.py` |
| 4.2 Canonical-Path Cleanup and Legacy Removal | ✅ Done | - | - | `src/prodbox/cli/gateway.py`, `src/prodbox/settings.py`, `src/prodbox/cli/summary.py`, `src/prodbox/lib/lint/` |
| 4.3 Adaptive Edge Infrastructure Reconcile and Ingress Ownership | ✅ Done | - | - | Infra modules, CLI modules, `tests/integration/test_charts_platform.py` |
| 4.4 In-Cluster Gateway Daemon and DNS Continuity | ✅ Done | - | - | `charts/gateway/`, `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/lib/chart_platform.py`, `tests/integration/test_gateway_k8s_pods.py`, `tests/integration/test_gateway_partition.py` |
| 4.5 Storage Path Migration, Single StorageClass, and HA Doctrine | ✅ Done | - | - | `src/prodbox/lib/chart_platform.py`, `src/prodbox/lib/prodbox_k8s.py`, `src/prodbox/settings.py`, chart templates and values |
| 4.6 Configuration Simplification, Secret Boundary, and PV-Only Storage Root | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/lib/chart_platform.py`, `src/prodbox/cli/dag_builders.py`, infra modules |
| 4.7 Dhall Config Schema, Bootstrap, and Manual PV Host Root | ✅ Done | - | - | `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, CLI modules |
| 4.8 Settings Migration and AWS Auth Removal | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/lib/aws_auth.py` (deletion), `src/prodbox/cli/interpreter.py`, `tests/conftest.py` |
| 4.9 Subprocess Credential Isolation and Legacy Cleanup | ✅ Done | - | - | `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/env.py` (removal) |
| 4.10 AWS Fixture Leak Prevention | ✅ Done | - | - | `tests/integration/conftest.py`, `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/main.py`, `tests/integration/sweep_runner.py` |
| 4.11 Final Subprocess Env Isolation and Settings-Only Config Access | ✅ Done | - | - | `src/prodbox/cli/check_code.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/interpreter.py` |
| 4.12 Host Gateway Service Removal | ✅ Done | - | - | `src/prodbox/cli/gateway.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, host filesystem, `documents/engineering/*`, `DEVELOPMENT_PLAN/*` |
| 4.13 Per-Test AWS Fixture Hygiene and Resource Tagging | ✅ Done | - | - | `tests/integration/aws_helpers.py`, `tests/integration/conftest.py`, `tests/integration/test_aws_foundation_real.py`, `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/lib/aws_fixture_audit.py` |
| 4.14 Full Cluster Delete, StorageClass Reset, and Reinstall Rebinding | ✅ Done | - | - | `src/prodbox/cli/rke2.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_prodbox_lifecycle.py` |
| 5.1 Public Hostname Closure and Authoritative External Proof | ✅ Done | - | - | `prodbox-config.dhall`, `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/infra/cluster_issuer.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/test_public_dns_delegation.py` |
| 6.1 Final Clean-Room Validation Rerun and Zero-Legacy Handoff | ✅ Done | - | - | `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/infra/cert_manager.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/metallb.py`, `tests/unit/test_infra_program.py`, `tests/unit/test_test_cmd.py` |
| 6.2 Clean-Cluster Aggregate Bootstrap and Zero-AWS-Residue Closure | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/test_cmd.py`, `tests/unit/test_settings.py`, `tests/integration/test_cli_env.py`, `tests/integration/test_charts_vscode.py`, `src/prodbox/lib/aws_fixture_audit.py` |
| 6.3 Final Handoff Proof from Full Cluster Delete and Missing Compiled Config | ✅ Done | - | - | `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `tests/integration/test_prodbox_lifecycle.py` |

## Current Plan Status

As of April 13, 2026: **the plan is closed.**
The remaining April 13 doctrine deltas were implemented and revalidated on the supported host:

- `prodbox` now owns the RKE2 cluster lifecycle on `Ubuntu 24.04 LTS`, including
  `install|delete` and reboot-time systemd enablement.
- `prodbox-config.dhall` explicitly declares `storage.manual_pv_host_root`, defaulting to the
  repository `.data/` directory.
- Full cluster delete now preserves the configured manual PV host root plus the repo-local
  `.prodbox-state/` retained chart-state root, recreates `manual`, deletes every other
  StorageClass, and re-proves PVC/PV rebinding after reinstall.

Current-environment validation snapshot:

- `poetry run prodbox rke2 delete --yes` passed on April 13, 2026 and reported preserved roots
  `/home/matthewnowak/prodbox/.data` and `/home/matthewnowak/prodbox/.prodbox-state`.
- `rm -f prodbox-config.json` removed the compiled config before the closure rerun.
- `poetry run prodbox rke2 install` passed on April 13, 2026 in `6m 40s`.
- `poetry run prodbox config show` and `poetry run prodbox config validate` both passed on
  April 13, 2026 and auto-regenerated `prodbox-config.json`; `config show` reported
  `storage.manual_pv_host_root=/home/matthewnowak/prodbox/.data`.
- `systemctl is-enabled rke2-server` returned `enabled`, and `/etc/os-release` reported
  `Ubuntu 24.04.4 LTS`.
- `poetry run prodbox test all` passed on April 13, 2026 in `1h 27m 34s` from full cluster
  delete plus missing compiled config and restored the runtime to
  `CLASSIFICATION=ready-for-external-proof`.
- `poetry run prodbox host public-edge`, `poetry run prodbox test integration public-dns`, and
  `poetry run prodbox check-code` all passed on April 13, 2026.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) has no pending removal items.

## Exit Definition

This plan is done only when all of the following are true:

1. Sprint 1.3 closes with `prodbox` owning the RKE2 cluster lifecycle on `Ubuntu 24.04 LTS`
   only, including install, delete, and the system-level service enablement needed for restart
   after reboot.
2. Sprint 4.1 remains closed without retry-based cleanup settling in the lifecycle suite.
3. Sprint 4.2 remains closed with one canonical runtime path, one canonical CLI path, and one
   canonical automated validation path per major surface.
4. Sprint 4.3 remains closed with one coherent public-edge ownership model: adaptive MetalLB
   addressing, Traefik as the supported cluster-edge controller, cert-manager bootstrap ownership,
   and no competing public ingress path.
5. Sprint 4.4 remains closed with the gateway daemon running as an in-cluster Kubernetes workload
   under `prodbox charts`, with leader election guaranteeing exactly one Route 53 writer,
   partition tolerance proven by a named integration suite, and explicit public subdomain
   Route 53 records kept current through `dns_write_gate`.
6. Sprint 4.5 remains closed with one StorageClass named `manual`, the 5-segment retained PV path
   scheme, explicit replica counts aligned to each chart's storage semantics, and no residual
   4-segment path references outside completed-sprint history.
7. Sprint 4.6 closes with the configured manual PV host root reserved purely for PV contents; no
   generated secrets, gateway mesh keys, or other non-PV retained artifacts may live there.
8. Sprint 4.7 closes with `prodbox-config.dhall` as the single config source and with an explicit
   manual PV host-root field that defaults to the repository `.data/` directory; canonical settings
   loads must continue auto-compiling JSON when the compiled artifact is missing or stale.
9. Sprint 4.8 remains closed with `Settings` loading from JSON (not `.env`), `pydantic-settings`
   removed, `aws_auth.py` deleted, and all AWS credential access flowing through `Settings`.
10. Sprint 4.9 remains closed with subprocess environments built explicitly from configuration (no
    `os.environ` inheritance), `prodbox env` removed, and all `.env` code deleted.
11. Sprint 4.10 remains closed with AWS leak prevention independent of host cron supervision or any
    other standalone long-running janitor surface outside the RKE2 cluster.
12. Sprint 4.11 remains closed with all subprocess env builders using explicit allowlists (no
    `os.environ` inheritance) and all config access flowing through `Settings` (no env fallbacks).
13. Sprint 4.12 remains closed with `prodbox-gateway.service` uninstalled from the supported host,
    `prodbox gateway install-service` removed from the CLI surface, and all "host supervisor"
    language purged from the plan and doctrine docs.
14. Sprint 4.13 remains closed with every AWS-mutating integration test beginning by sweeping any
    pre-existing fixture-owned AWS resources discoverable by canonical tags before creating fresh
    ones, every taggable fixture-owned AWS resource carrying the canonical
    ownership/expiry/safe-delete tags as the stale-resource discovery contract, setup helpers
    rolling back partial AWS creation before the fixture yields, and no session-scoped sweep or
    standalone janitor surface remaining on the supported path.
15. Sprint 4.14 closes with `prodbox rke2 install` recreating the cluster-scoped `manual`
    StorageClass and deleting every other StorageClass, `prodbox rke2 delete --yes` wiping every
    managed cluster remnant other than the configured manual PV host root plus the repo-local
    `.prodbox-state/` retained chart-state root, and lifecycle validation proving deterministic
    PVC/PV rebinding after delete/reinstall.
16. Sprint 5.1 remains closed with authoritative public DNS delegation proof plus live TLS and
    auth-wall verification for `vscode.resolvefintech.com`.
17. Sprint 6.1 remains closed with doctrine-aligned validation reruns from canonical CLI
    entrypoints and with no competing sprint narrative under `documents/`.
18. Sprint 6.2 remains closed with a canonical aggregate rerun restoring the public-edge stack
    without manual Pulumi, Helm, host resolver, or config-compilation intervention from the
    prior `cleanup`-based baseline.
19. Sprint 6.3 closes with the authoritative clean-room handoff rerun starting from
    `poetry run prodbox rke2 delete --yes` plus a missing repository-root `prodbox-config.json`,
    preserving the configured PV-content root plus the repo-local `.prodbox-state/` retained
    chart-state root while deleting every other managed cluster remnant, then restoring the
    supported runtime and ending at `CLASSIFICATION=ready-for-external-proof`.
20. Sprint 6.3 also closes with authoritative public-host proof using public DNS only (no
    `/etc/hosts` override for `vscode.resolvefintech.com`) and with the aggregate supported test
    flow proving that no fixture-owned Route 53, S3, VPC, EKS, or IAM resources remain without
    invoking a standalone AWS janitor command outside the test harness.
21. The remaining legacy inventory is empty.

## Related Documents

- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [../README.md](../README.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
- [../documents/documentation_standards.md](../documents/documentation_standards.md)
