# Historical Documentation and Evidence

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Historical navigation; never authoritative runtime instructions or current phase closure.

> **Purpose**: Preserve traceability without carrying old implementation diaries into active architecture and execution documents.

## Source baseline

Before adoption, the tracked documentation and source baseline was Git revision
`583443fbe233df3327b5be12a236b001622a1e66` (short form `583443f`). Inspect
original text with `git show 583443f:PATH`. This is a read-only history lookup,
not an instruction to restore old code or execute its commands. Original phase
filenames, decimal statuses, closed claims and completed-removal history remain
attributable to that revision.

References to a section from that baseline identify the document, revision and
section explicitly, for example `config_doctrine.md at 583443f, section 6`.
The checker resolves the preserved document and section at that revision;
missing Git history is an unavailable reference, not a successful check.

- [Original refactor proposal](refactor_proposal_2026_11.md): the reviewed design before Markdown adoption. Its old queue, proposed YAML filenames and migration wording are historical, not the active plan.
- [Every pending legacy obligation](legacy_pending_baseline.md): preserves all 81 original pending item/owner/note cells, mapped to B001–B081 in the [active ledger](../../DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md). Quoted historical links/locations are source evidence, not current navigation.
- [Manual AWS cleanup](aws_cleanup_2026_11.md): explicitly authorized hand actions and their scope, not lifecycle qualification or a permanent assertion that AWS remains clean.

The current queue is [Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here). No old Done or live-proof record automatically closes a new phase. Current engineering docs own the accepted target. Deprecated old-path files are short forwarding material for unmigrated code references; they must not reintroduce old doctrine.

## Non-versioned evidence

Existing `.build/sprint-*` and other operational artifacts may contain inputs needed to reproduce old failures. They are not removed by this Markdown refactor. Before deleting them, L20/B rows require an availability/retention manifest, source/build/contract binding and an explicit remover. Never ingest or hash plaintext secret fixture/data roots to create such a manifest. A missing local artifact is unavailable evidence, not proof of cleanup or migration.

Historical snapshots may quote links, source paths and executable examples that were valid only at their original revision. Keep such quotations separate from active link/command validation; all active documents still require resolving links and honest current/target applicability.
