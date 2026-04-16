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
| [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md) | Phase 7: Interactive onboarding, AWS IAM, and quota automation |
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
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation | ✅ Done | [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md) |

**Status interpretation**: phase status is scoped to the surface owned by that phase. As of
April 15, 2026, all phases 0-7 are closed on their owned surfaces, and the zero-legacy ledger is
empty in `Pending Removal`.

**Canonical architecture**: one supported `prodbox` CLI surface, one repository-root Dhall
config auto-compiled idempotently to JSON when supported commands load settings, one supported
host OS (`Ubuntu 24.04 LTS` with systemd), one host-owned local
`prodbox rke2 install|delete --yes|status|start|stop|restart|logs` lifecycle for the test-runner
cluster itself, two intended AWS-backed cluster deployment and validation patterns under
`prodbox`: one EKS-backed path and one SSH-driven HA RKE2 path against three Pulumi-managed
`Ubuntu 24.04 LTS` EC2 instances in separate AZs. One local-cluster MinIO backend for AWS test
stacks with one dedicated bucket named
`prodbox-test-pulumi-backends`, Pulumi-exclusive AWS provisioning and deprovisioning for test
resources through named `prodbox pulumi eks-resources|eks-destroy --yes` and
`prodbox pulumi test-resources|test-destroy --yes` surfaces, automatic destroy of both AWS test
stacks during `prodbox rke2 delete --yes` before the local backend cluster is removed, aggregate
supported-runtime repair that idempotently selects or creates the canonical Pulumi `home` stack
before raw Pulumi AWS/provider repair runs, one
in-cluster always-on gateway Route 53 write path through `dns_write_gate` managed by
`prodbox charts` (no host-side daemons), explicit per-subdomain Route 53 records only, one
coherent `MetalLB -> Traefik -> vscode-nginx` public-host stack, one cluster-backed
`prodbox charts` delivery path for `vscode`, one named validation command per major surface, one
explicit removal ledger for anything still scheduled to disappear, one cluster-wide StorageClass
named `manual` recreated at cluster install while every other StorageClass is deleted, one
config-declared manual PV host root (default repository `.data/`) reserved purely for PV content,
one repo-local retained chart-state root `.prodbox-state/` for generated secrets and gateway
event keys preserved across cluster delete/reinstall cycles, one explicit PV pre-creation model
with deterministic PVC/PV rebinding across cluster delete/reinstall cycles, one Helm-only service
deployment path, explicit chart-owned replica counts that keep single-writer retained-state
services single-replica, and subprocess credential isolation with no `os.environ` inheritance. One `prodbox config setup`
interactive onboarding wizard that populates all `prodbox-config.dhall` fields from live AWS
queries, ACME provider guidance, and user input including AWS account creation instructions and
Free Tier options. One `prodbox aws` IAM and quota management surface for standalone user
lifecycle and policy generation via ephemeral admin credentials and AWS CLI subprocess. One
`aws_admin` Dhall config section for test-only elevated credentials ignored by all non-test
commands.

### Sprint Details

| Sprint | Status | Blocked by | Remaining Work | Implementation |
|--------|--------|------------|----------------|----------------|
| 0.1 Planning and Documentation Topology Baseline | ✅ Done | - | - | `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`, `documents/engineering/README.md` |
| 1.1 Runtime, CLI, and Test-Command Foundations | ✅ Done | - | - | `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `tests/integration/test_cli_commands.py`, `tests/integration/test_cli_env.py` |
| 1.2 AWS Auth Doctrine and Real-System Validation Foundation | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/aws_helpers.py`, `tests/integration/test_dns_route53_aws.py`, `tests/integration/test_pulumi_real.py` |
| 1.3 Supported Host Gate and Host-Owned RKE2 Cluster Lifecycle | ✅ Done | - | - | `src/prodbox/cli/rke2.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/prerequisite_registry.py`, `src/prodbox/settings.py` |
| 1.4 SSH-Driven HA RKE2 on Pulumi-Managed Ubuntu 24.04 EC2 Nodes | ✅ Done | - | - | `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/infra/aws_test_stack_program.py`, `src/prodbox/lib/aws_test_stack.py`, `src/prodbox/lib/ha_rke2_aws.py`, `tests/integration/test_ha_rke2_aws.py`, `tests/integration/test_pulumi_real.py` |
| 1.5 EKS-Backed AWS Deployment and Validation Path | ✅ Done | - | - | `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/infra/aws_eks_test_stack_program.py`, `src/prodbox/lib/aws_eks_test_stack.py`, `src/prodbox/cli/test_cmd.py`, `tests/integration/test_aws_eks.py` |
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
| 4.10 AWS Fixture Leak Prevention | ✅ Done | - | - | `tests/integration/conftest.py`, `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/main.py`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` |
| 4.11 Final Subprocess Env Isolation and Settings-Only Config Access | ✅ Done | - | - | `src/prodbox/cli/check_code.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/interpreter.py` |
| 4.12 Host Gateway Service Removal | ✅ Done | - | - | `src/prodbox/cli/gateway.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, host filesystem, `documents/engineering/*`, `DEVELOPMENT_PLAN/*` |
| 4.13 Per-Test AWS Fixture Hygiene and Resource Tagging | ✅ Done | - | - | `tests/integration/aws_helpers.py`, `tests/integration/test_dns_route53_aws.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/test_pulumi_real.py` |
| 4.14 Full Cluster Delete, StorageClass Reset, and Reinstall Rebinding | ✅ Done | - | - | `src/prodbox/cli/rke2.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_prodbox_lifecycle.py` |
| 4.15 Pulumi-Owned AWS Test Stack Lifecycle and Auto-Teardown | ✅ Done | - | - | `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/lib/aws_test_stack.py`, `src/prodbox/infra/aws_test_stack_program.py`, `tests/integration/test_pulumi_real.py`, `tests/integration/test_ha_rke2_aws.py` |
| 5.1 Public Hostname Closure and Authoritative External Proof | ✅ Done | - | - | `prodbox-config.dhall`, `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/infra/cluster_issuer.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/test_public_dns_delegation.py` |
| 6.1 Final Clean-Room Validation Rerun and Zero-Legacy Handoff | ✅ Done | - | - | `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/infra/cert_manager.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/metallb.py`, `tests/unit/test_infra_program.py`, `tests/unit/test_test_cmd.py` |
| 6.2 Clean-Cluster Aggregate Bootstrap and Zero-AWS-Residue Closure | ✅ Done | - | - | `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/test_cmd.py`, `tests/unit/test_settings.py`, `tests/integration/test_cli_env.py`, `tests/integration/test_charts_vscode.py`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md` |
| 6.3 Final Handoff Proof from Full Cluster Delete and Missing Compiled Config | ✅ Done | - | - | `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `tests/integration/test_prodbox_lifecycle.py` |
| 6.4 Final Clean-Room Proof for Local-Backend and Remote-HA Validation | ✅ Done | - | - | `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/rke2.py`, `src/prodbox/lib/aws_test_stack.py`, `tests/integration/test_ha_rke2_aws.py` |
| 6.5 Final Clean-Room Proof for Dual AWS Deployment Patterns | ✅ Done | - | - | `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/infra/aws_eks_test_stack_program.py`, `src/prodbox/lib/aws_eks_test_stack.py`, `tests/integration/test_aws_eks.py`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md` |
| 7.1 IAM Policy Generation and `prodbox aws policy` | ✅ Done | - | - | `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `tests/unit/test_phase7_commands.py`, `tests/integration/test_cli_commands.py` |
| 7.2 Interactive Configuration Wizard | ✅ Done | - | - | `src/prodbox/cli/config_cmd.py`, `src/prodbox/lib/aws_admin.py`, `tests/unit/test_aws_admin.py`, `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`, `README.md` |
| 7.3 Standalone IAM User Lifecycle | ✅ Done | - | - | `src/prodbox/cli/aws_cmd.py`, `src/prodbox/lib/aws_admin.py`, `tests/unit/test_aws_admin.py`, `documents/engineering/cli_command_surface.md` |
| 7.4 Service Quota Inspection and Request Automation | ✅ Done | - | - | `src/prodbox/cli/aws_cmd.py`, `src/prodbox/lib/aws_admin.py`, `tests/unit/test_aws_admin.py`, `documents/engineering/cli_command_surface.md` |
| 7.5 Elevated Credential Harness and Full IAM Lifecycle Validation | ✅ Done | - | - | `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `tests/integration/test_aws_iam_lifecycle.py`, `documents/engineering/aws_admin_credentials.md` |

## Current Plan Status

As of April 15, 2026: **all phases 0-7 are closed on their owned surfaces. Sprint 1.5 and
Sprint 6.5 closed during the April 15, 2026 destructive rerun, and the zero-legacy ledger is
empty in `Pending Removal`.**

Fresh validation established:

- `poetry run prodbox check-code` passed on April 15, 2026 after the final
  status-documentation refresh.
- `poetry run prodbox test unit` passed on April 15, 2026 (`1078 passed`).
- `poetry run prodbox test integration aws-iam` passed on April 14, 2026 (`2 passed`).
- `poetry run prodbox test integration lifecycle` passed on April 15, 2026 (`2 passed` in `16m 06s`), proving that the internal `rke2 install` path now republishes Harbor images correctly after the fully pruned Docker baseline.
- `poetry run prodbox rke2 delete --yes`, `rm -f prodbox-config.json`, `poetry run prodbox rke2 install`, `poetry run prodbox config show`, and `poetry run prodbox config validate` passed on April 13, 2026 from the missing compiled-config baseline required by the clean-room handoff.
- `poetry run prodbox pulumi eks-resources`, `poetry run prodbox test integration aws-eks`, and
  `poetry run prodbox pulumi eks-destroy --yes` passed on April 15, 2026; the named EKS suite
  `tests/integration/test_aws_eks.py` passed (`1 passed` in `22m 03s`).
- `poetry run prodbox pulumi test-resources` passed on April 14, 2026 and created the canonical `aws-test` stack with three Pulumi-managed EC2 nodes in separate availability zones.
- `poetry run prodbox pulumi test-destroy --yes` passed on April 14, 2026 and again in the April 15, 2026 aggregate postflight, each time verifying no AWS residue plus an empty backend bucket `prodbox-test-pulumi-backends`.
- `poetry run prodbox rke2 delete --yes`, `docker system prune -af --volumes`, `sudo rm -rf .data`,
  and `poetry run prodbox test all` all passed on April 15, 2026 from a local file-backed Pulumi
  backend with no active stack selection; the aggregate rerun finished in `1h 42m 48s`, selected
  or created the canonical `home` stack during supported-runtime repair, exercised
  `tests/integration/test_public_dns_delegation.py`,
  `tests/integration/test_aws_eks.py`, `tests/integration/test_pulumi_real.py`,
  `tests/integration/test_ha_rke2_aws.py`, `tests/integration/test_gateway_k8s_pods.py`,
  `tests/integration/test_charts_platform.py`, `tests/integration/test_prodbox_lifecycle.py`, and
  `tests/integration/test_aws_iam_lifecycle.py`, restored the supported runtime to
  `CLASSIFICATION=ready-for-external-proof`, and auto-destroyed both `aws-eks-test` and
  `aws-test` with no residue.

Implication:

- Sprint 1.4 and Sprint 1.5 are fully validated in the worktree: the HA RKE2 and EKS-backed AWS
  paths both exist and close through named `prodbox` create/validate/destroy surfaces.
- Sprint 6.4 and Sprint 6.5 are both closed on the supported clean-room handoff path, including
  the pruned-Docker and deleted-`.data` destructive rerun.
- Sprint 7.1 through Sprint 7.5 are closed in the worktree with aligned documentation and test
  coverage.
- The remaining legacy ledger has no pending-removal entries.

## Exit Definition

This plan is done only when all of the following are true:

1. Sprint 1.3 remains closed with `prodbox` owning the local host RKE2 lifecycle on
   `Ubuntu 24.04 LTS`, including install, delete, and reboot-time systemd enablement.
2. Sprint 1.4 remains closed with `prodbox` able to deploy RKE2 in HA mode over SSH against
   exactly three Pulumi-managed `Ubuntu 24.04 LTS` EC2 instances placed in separate AWS
   availability zones.
3. Sprint 1.5 closes with a supported EKS-backed AWS deployment and validation path alongside
   Sprint 1.4; neither AWS-backed cluster pattern replaces the other.
4. The local host cluster is still bootstrapped first and hosts the Pulumi backend for AWS test
   stacks through MinIO and the dedicated bucket `prodbox-test-pulumi-backends`.
5. Sprint 4.15 remains closed with Pulumi as the exclusive creator and destroyer of AWS test
   resources; no canonical ownership/expiry/safe-delete tag contract, pre-test AWS sweep, or
   standalone janitor surface remains.
6. Named `prodbox` surfaces exist for the supported AWS-backed validation paths, and each path
   proves explicit create, inspect, and destroy behavior against the same cleanup doctrine.
7. `prodbox rke2 delete --yes` automatically invokes the shared AWS EKS and HA test-stack destroy
   paths before the local cluster that hosts the MinIO backend is removed.
8. Previously closed gateway, ingress, DNS, public-host, config, and retained-storage sprints
   remain closed on the supported path: one `manual` StorageClass, one in-cluster gateway Route 53
   writer through `dns_write_gate`, Traefik as the only supported edge controller, and
   `prodbox-config.dhall` as the single configuration source.
9. Sprint 6.2 remains closed with canonical settings loads auto-compiling `prodbox-config.json`
   when the compiled artifact is missing or stale.
10. Sprint 6.2 also remains closed with aggregate supported-runtime repair idempotently selecting
    or creating the canonical Pulumi `home` stack, so `poetry run prodbox test all` does not
    require a manual `pulumi stack select`.
11. Sprint 6.3 remains closed with full local-cluster delete preserving only the configured
    PV-content root plus `.prodbox-state/` and with deterministic PVC/PV rebinding after
    delete/reinstall.
12. Sprint 6.4 remains closed for the implemented HA RKE2 clean-room rerun path from
    `poetry run prodbox rke2 delete --yes` plus a missing `prodbox-config.json` through final AWS
    destroy and public-host restore.
13. Sprint 6.5 closes with a final clean-room rerun that proves both the EKS-backed path and the
    HA RKE2 path from the supported baseline and leaves no Pulumi-managed Route 53, VPC, subnet,
    security-group, EC2, IAM, EKS, or backend-bucket residue behind.
14. The remaining legacy inventory has no pending-removal entries.
15. `prodbox aws policy` emits valid IAM inline policy JSON for both `core` and `full` tiers,
    covering all permissions required by the supported architecture.
16. `prodbox config setup` walks a new user from zero through AWS account creation guidance,
    region and Route 53 zone selection from live AWS queries, ACME provider guidance with Free Tier
    options (ZeroSSL with EAB or Let's Encrypt), domain and deployment configuration, dedicated
    IAM user creation with a single inline policy, and complete `prodbox-config.dhall` generation,
    compilation, and validation — using ephemeral admin credentials that are never persisted.
17. `prodbox aws setup` creates a dedicated IAM user with the consolidated inline policy, creates
    access keys, injects operational credentials into `prodbox-config.dhall`, and ensures baseline
    service quotas (auto-approvable: 32 Standard vCPU, 10 VPCs, 10 internet gateways) via
    ephemeral admin credentials.
18. `prodbox aws teardown` deletes the IAM user, all access keys, and the inline policy, clears
    `aws.*` credentials in Dhall config, and recompiles.
19. `prodbox aws check-quotas` and `prodbox aws request-quotas` inspect and request service quota
    increases via ephemeral admin credentials and the AWS CLI Service Quotas API.
20. The `aws_admin` section in `prodbox-config-types.dhall` provides test-only elevated
    credentials that are ignored by all prodbox commands outside `prodbox aws *` and the test
    suite. Normal `aws.*` operational credentials are populated exclusively through the interactive
    `prodbox config setup` or `prodbox aws setup` flows.
21. Integration tests validate the full IAM user lifecycle (create → verify → delete) using
    `aws_admin.*` credentials from config.

## Related Documents

- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [../README.md](../README.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
- [../documents/documentation_standards.md](../documents/documentation_standards.md)
