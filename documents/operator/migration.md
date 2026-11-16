# Original-Install Migration

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Phase 10 target import workflow; no current storage move or code cutover was performed by documentation adoption.

> **Purpose**: Preserve original deployment identity, custody and cleanup while moving RKE2-era installations to the accepted kind model.

## Required ordering

1. Inventory exact original roots, Vault/journal identities, pending operations, resources and ownership. Preserve source/build/schema bindings and still-needed evidence. A blank current Vault does not erase older recorded obligations.
2. Freeze new admission under the old writer. Keep only the fenced exact original-install cleanup/import lane needed by those identities. It is not a generic fallback for new deployments.
3. Settle or explicitly retain every old operation. Snapshot and independently verify the original local custody and ownership records. Do not infer a clean resource field from absent checkpoints or a disappeared directory.
4. Restore kind using the exact logical deployment scope and host root generation. Never initialize a new Vault over existing data or reuse the old AWS identity for a new storage-canary.
5. Confirm restored state, the new caller and old-writer rejection before switching ownership. Two Authorities cannot mutate one scope. Keep an explicit reversible boundary; after new effects occur recover forward rather than restart stale old state.
6. Resume actual public operations, verify resource/credential/state disposition, repeat deletion/no-op, and confirm retained control health. Missing/foreign/corrupt evidence remains a specific recovery condition.
7. Remove migration-only readers/codecs/helpers only after the actual supported original identities and their obligations are resolved. Follow L18/L19/B rows, not an old Done label.

Use a real disposable old-layout fixture to qualify this sequence before applying it to an operator's retained installation. The final phase repeats all previously established workflows; ordinary new kind deployments already use their delivered public slices.

## Existing host caveat

Historical inspection found a declared legacy test root and an unlinked Vault mount. Neither this documentation adoption nor the manual AWS inventory reset local storage or established usable retained custody. That exact path/provenance must be resolved before mutation. Do not interpret the [manual cloud cleanup](../history/aws_cleanup_2026_11.md) as authority to purge `.data/` or `.test-data/`.

[Phase 10](../../DEVELOPMENT_PLAN/phase_10_migration_and_final_regression.md) owns real implementation and evidence. [Storage](../engineering/storage.md) owns local retention/destruction semantics.
