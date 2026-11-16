# Vault Doctrine — Deprecated Path

**Status**: Deprecated
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Temporary path compatibility for unchanged code; not accepted security doctrine.

> **Purpose**: Forward old Vault references without retaining conflicting metadata concealment or credential/bootstrap policy.

[Security and credentials](security_and_credentials.md) owns production/test custody, unlock, scoped operational secrets and elevated input. [Lifecycle](lifecycle.md) owns non-secret admission metadata, provider observations and exact deletion. In particular, the former whole-system zero-child-information policy is superseded: useful authenticated lifecycle metadata remains available while secret payloads stay protected. Test-only MinIO self-unseal is an explicit distinct policy.

The original text is historical at `583443f:documents/engineering/vault_doctrine.md`. This stub remains only until Phase 0 migrates unchanged source/checker references and retires it under L03 in the [active ledger](../../DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md). [Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here) is the only work queue.
