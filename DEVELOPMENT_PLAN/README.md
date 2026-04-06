# File: DEVELOPMENT_PLAN/README.md
# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../documents/engineering/README.md](../documents/engineering/README.md)

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
| 4 | Lifecycle Hardening and Canonical-Path Cleanup | ⏸️ Blocked | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Public Hostname Closure and Authoritative External Proof | ⏸️ Blocked | [phase-5-public-host-validation.md](phase-5-public-host-validation.md) |
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | ⏸️ Blocked | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |

**Canonical architecture**: one supported `prodbox` CLI surface, one repository-root `.env`
configuration source, one gateway Route 53 write path through `dns_write_gate`, one cluster-backed
`prodbox charts` delivery path for `vscode`, one named validation command per major surface, and
one explicit removal ledger for anything still scheduled to disappear.

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
| 4.2 Canonical-Path Cleanup and Legacy Removal | ⏸️ Blocked | External AWS Route 53 permissions for rerunning `dns-aws`, `pulumi`, and `public-dns` | Rerun the blocked AWS-backed validation gates and close the last canonical-path cleanup proof | `src/prodbox/cli/gateway.py`, `src/prodbox/settings.py`, `src/prodbox/lib/lint/` |
| 5.1 Public Hostname Closure and Authoritative External Proof | ⏸️ Blocked | Sprint 4.2 plus external edge routing or reachability outside the repo | Restore live HTTP/HTTPS reachability for `vscode.resolvefintech.com` and rerun the public-host proof suites | `tests/integration/test_charts_vscode.py`, `tests/integration/test_public_dns_delegation.py` |
| 6.1 Final Clean-Room Validation Rerun and Zero-Legacy Handoff | ⏸️ Blocked | Sprint 4.2 and Sprint 5.1 | Rerun the final clean-room validation set once the remaining blocked proofs close | `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md` |

## Current Plan Status

As of April 6, 2026:

- Completed and closed: Phases 0 through 3, plus Sprint 4.1.
- Blocked but partially implemented: Sprint 4.2 and Sprint 5.1.
- Not yet closable: Sprint 6.1, because it depends on the blocked work above.

Current-environment rerun blockers:

- `poetry run prodbox test integration dns-aws` is blocked because the active AWS identity lacks
  `route53:CreateHostedZone`.
- `poetry run prodbox pulumi up --yes` is blocked because the active AWS identity lacks
  `route53:GetHostedZone` for the configured hosted zone path.
- `poetry run prodbox test integration public-dns` is blocked because the active AWS identity lacks
  `route53:GetHostedZone` for `ROUTE53_ZONE_ID`.
- HTTP and HTTPS requests to `vscode.resolvefintech.com` still time out before reaching the
  canonical ingress path, so live public-host closure remains blocked outside the repository.

## Exit Definition

This plan is done only when all of the following are true:

1. Sprint 4.1 remains closed without retry-based cleanup settling in the lifecycle suite.
2. Sprint 4.2 closes with one canonical runtime path, one canonical CLI path, and one canonical
   automated validation path per major surface.
3. Sprint 5.1 closes with authoritative public DNS delegation proof plus live TLS and auth-wall
   verification for `vscode.resolvefintech.com`.
4. Sprint 6.1 reruns the full clean-room validation set from canonical CLI entrypoints only.
5. No document under `documents/` carries a competing sprint narrative or completion-status track.
6. The remaining legacy inventory is empty.

## Related Documents

- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [../README.md](../README.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
- [../documents/documentation_standards.md](../documents/documentation_standards.md)
