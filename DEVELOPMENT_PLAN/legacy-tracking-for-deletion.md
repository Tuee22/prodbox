# File: DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md
# Legacy Tracking

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)

> **Purpose**: Track every known compatibility helper, duplicate surface, deprecated path, and
> stale tooling residue that still needs removal outside the declarative phase narrative.

> **Authoritative Reference**: [development_plan_standards.md](development_plan_standards.md#i-explicit-cleanup-and-removal-ledger)

## Pending Removal

None currently identified.

Repository-external blockers still remain in the plan, but they are not repo-internal legacy items.

## Completed

| Item | Removed In | Notes |
|------|------------|-------|
| Competing implementation-status narratives in doctrine docs | Sprint 0.1 | `documents/` now defer status and blocker tracking to the development plan |
| Runtime placeholders that reported success without performing documented behavior | Sprint 1.1 | Removed inert command behavior from the supported CLI surface |
| Unconditional prerequisite success paths | Sprint 1.1 | Placeholder prerequisite success is no longer supported |
| Raw pytest passthrough from the public `prodbox test` surface | Sprint 1.1 | Only named suites remain public |
| Undocumented command-surface side paths | Sprint 1.1 | Click surface is now explicitly owned and documented |
| Ambient or shared-profile AWS auth assumptions | Sprint 1.2 | Repository-root `.env` is the sole supported source |
| Unnamed high-risk AWS real-system validation | Sprint 1.2 | AWS-backed validation now runs through named suites |
| Implicit cleanup assumptions for AWS suites | Sprint 1.2 | Teardown and cleanup proof are explicit closure work |
| Cross-namespace chart composition | Sprint 3.1 | Chart delivery is namespace-local and canonical |
| Chart-authored `PersistentVolume` creation | Sprint 3.1 | Retained storage is CLI-owned and deterministic |
| `oauth2-proxy` and Google OAuth as the supported `vscode` auth path | Sprint 3.2 | nginx OIDC plus local Keycloak users is canonical |
| Stale oauth2 or Google auth naming in chart metadata and fixtures | Sprint 3.2 | Chart and test inputs match the supported auth path |
| Unsupported `docker/vscode-dev` repository files | Sprint 3.2 | Cluster-backed `prodbox charts` is the only supported delivery model |
| `CleanupProdboxAnnotatedResources.cleanup_passes` | Sprint 4.1 | Retry-count based cleanup flow is gone |
| Multi-pass `_collect_annotated_refs` and `_delete_ref` cleanup loop | Sprint 4.1 | Namespace-first cascade cleanup is canonical |
| Retry-as-settling behavior after cleanup | Sprint 4.1 | Lifecycle validation now passes without the post-cleanup rerun shim |
| `rke2_killall_exists` prerequisite | Sprint 4.2 | Compatibility-only prerequisite residue has been removed |
| Legacy Poetry `daemon` entrypoint alongside `prodbox gateway start` | Sprint 4.2 | One supported gateway startup path remains |
| CLI/DDNS timer Route 53 path alongside gateway `dns_write_gate` | Sprint 4.2 | Route 53 updates are canonical through the gateway |
| Interpreter command-summary compatibility bridge | Sprint 4.2 | Structured DAG outcomes are canonical |
| Hook-oriented `pre-commit` workflow residue | Sprint 4.2 | Repo development doctrine forbids hook-driven tooling |
| Cluster-gated invocation path for external public-host verification | Sprint 5.1 | `charts-vscode` no longer requires cluster prerequisite gates |
| Manual-only authoritative public DNS delegation proof | Sprint 5.1 | `poetry run prodbox test integration public-dns` is the named proof path |
