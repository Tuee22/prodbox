# File: DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md
# Phase 6: Final Clean-Room Rerun and Zero-Legacy Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the final repository handoff criteria: a full clean-room rerun through
> canonical entrypoints only and an empty remaining legacy inventory.

## Phase Summary

This phase reruns the authoritative validation set from the supported operator flow after the
blocked AWS and public-host proofs close. The repository hands off only when no sprint remains
blocked or active and the cleanup ledger is empty.

## Sprint 6.1: Final Clean-Room Validation Rerun and Zero-Legacy Handoff ⏸️

**Status**: Blocked
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`
**Blocked by**: Sprint 4.2, Sprint 4.3, Sprint 4.4, and Sprint 5.1
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Rerun the authoritative validation set from a clean operator flow and hand off a repository with no
remaining compatibility backlog.

### Deliverables

- Every remaining blocked sprint closes.
- The clean-room validation set reruns through canonical entrypoints only.
- Docs under `documents/` remain doctrine-only and defer status tracking to this plan suite.
- The remaining legacy inventory is empty.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration all`
4. `poetry run prodbox tla-check`
5. `poetry run prodbox test integration public-dns`

### Current Validation State

- `legacy-tracking-for-deletion.md` has no pending items. Sprint 4.6 (configuration
  simplification) is complete. The remaining blockers for final handoff are live-environment
  and AWS/public-host proofs.

### Remaining Work

- Close Sprint 4.2 in an AWS environment with the required Route 53 permissions.
- Close Sprint 4.3 by providing the Pulumi secrets passphrase, reconciling the live
  `MetalLB -> Traefik -> cert-manager -> vscode` edge, and rerunning the external `charts-vscode`
  proof path.
- Close Sprint 4.4 by installing the supported host `prodbox-gateway.service` with a real
  config/orders file and proving explicit-record DDNS continuity against live Route 53 state.
- Close Sprint 5.1 by restoring live public ingress reachability and rerunning the public-host
  proof path.
- Rerun the full clean-room validation set from canonical entrypoints only.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - final AWS-backed rerun posture.
- `documents/engineering/cli_command_surface.md` - canonical final validation path.
- `documents/engineering/helm_chart_platform_doctrine.md` - final `vscode` delivery and public-host
  posture.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained-storage posture at handoff.
- `documents/engineering/unit_testing_policy.md` - final authoritative test-command matrix.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep `README.md`, `documents/engineering/README.md`, and the cleanup ledger aligned with the
  final handoff status.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
