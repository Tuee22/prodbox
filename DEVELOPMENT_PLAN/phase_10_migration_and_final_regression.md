# Phase 10: Existing-Install Migration and Final Regression

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: Existing RKE2-era deployment identities migrate safely to kind, remaining migration-only paths are retired, and the final public workflow repeats the established proof without a late first cutover.

**Phase**: 10
**State**: Planned
**Prerequisites**: Phase 9 complete. Every ordinary capability and its real composition/cleanup/mutation proof already passed in its owning phase.
**Acceptance**: A10-01, A10-02, A10-03, A10-04 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M13 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L18, L19, L20 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B001, B002, B003, B004, B005, B006, B007, B008, B009, B010, B011, B012, B032, B048, B069, B070 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

Existing RKE2-era deployment identities migrate safely to kind, remaining migration-only paths are retired, and the final public workflow repeats the established proof without a late first cutover.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P10-T01** — Inventory each original identity/root/operation and exact owned cloud scope; preserve required source/backup/evidence. Do not erase unknown obligations with a fresh identity or initialize over an unlinked/missing old mount.
- [ ] **P10-T02** — Implement the bounded public admin migration lane: quiesce old admission/writer, settle or retain operations, verify snapshot, restore kind with the same logical identity, confirm new caller and old-writer rejection, then resume.
- [ ] **P10-T03** — Define and observe the point after which recovery is forward-only. Never resume an old writer from stale state after new effects; no two Authorities mutate the same scope.
- [ ] **P10-T04** — Run a real disposable old-layout migration fixture, missing/foreign/unsupported-schema and writer-conflict negatives, and M13. Existing operator data is not an implicit destructive test fixture.
- [ ] **P10-T05** — Rerun the full public real acceptance matrix under isolated production/test policies, real AWS/public-edge scenarios, concurrent isolation, current critical mutation catalog and declared repeated-cycle/soak budget.
- [ ] **P10-T06** — Resolve every remaining L18–L20 condition, remove migration-only readers/aliases/codecs/old RKE2 implementation after actual obligations end, and reconcile parser/help/docs/objectives/legacy inventory. Preserve needed historical reproducer artifacts in the evidence availability manifest.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-10`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A10-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A10-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A10-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A10-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M13 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Exact disposable old-layout fixtures, retained snapshots, pending operations, migration-only resources and final test campaigns. Every cloud family and disposable local artifact is read back absent; operator-owned retained data is removed only by separately authorized exact purge, never migration loading.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/operator/migration.md](../documents/operator/migration.md)
- [documents/engineering/lifecycle.md](../documents/engineering/lifecycle.md)
- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)
- [documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [ ] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [ ] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

All cumulative real cases and current critical mutations pass, declared soak completes, no owned pending/unowned removal or competing active doctrine remains, and the actual final public parser agrees with generated reference.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
