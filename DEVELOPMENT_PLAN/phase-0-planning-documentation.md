# Phase 0: Planning and Documentation Topology for Haskell Rewrite

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Define the plan-ownership baseline for the Haskell rewrite so status, sequencing,
> and Python-removal work have one canonical home.

## Phase Summary

This phase reopens the development plan against a Haskell-only repository handoff. The plan suite no
longer describes the previously closed Python architecture as the target end state. Instead, it
owns the execution-ordered rewrite narrative, the reopened phase model, and the Python-removal
ledger that later phases must close.

## Sprint 0.1: Reopen the Canonical Plan Suite for the Haskell Rewrite ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`, `DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`, `DEVELOPMENT_PLAN/phase-2-gateway-dns.md`, `DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md`, `DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`, `DEVELOPMENT_PLAN/phase-5-public-host-validation.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Rewrite the canonical plan suite so every phase reflects the Haskell end state and the complete
removal of Python from the supported architecture.

### Deliverables

- The top-level plan docs describe the Haskell rewrite rather than the closed Python architecture.
- Phase names `0-7` are retained, but their owned surfaces now target Haskell implementation work.
- The plan suite defines the build-artifact contract: `.build/` on the host and `/opt/build` in
  container builds.
- The legacy ledger is reopened with Python source, Python toolchain, and Python Pulumi removal
  work.

### Validation

1. `prodbox check-code`

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- None in this plan-suite rewrite. Governed doctrine alignment is owned by later implementation
  phases.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Root guidance docs already point at [README.md](README.md) as the canonical development-plan
  entrypoint.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
