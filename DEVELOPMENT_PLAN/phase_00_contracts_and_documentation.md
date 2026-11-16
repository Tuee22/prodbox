# Phase 00: Contracts, Documentation, and Tooling Adoption

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: A fresh session can select work from one numerical queue and the real checker enforces the adopted Markdown phase, command, acceptance, mutation, and removal contracts.

**Phase**: 0
**State**: Active
**Prerequisites**: Current checkout, existing Haskell build/test tooling, and the accepted Markdown contracts. No cluster, AWS credential, public DNS, or later phase is required.
**Acceptance**: A00-01, A00-02, A00-03, A00-04 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M00 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L01, L02, L03 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B071, B072, B073 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

A fresh session can select work from one numerical queue and the real checker enforces the adopted Markdown phase, command, acceptance, mutation, and removal contracts.

The documentation contract is being adopted in a Markdown-only change. The code checker, runtime, schemas, generated CLI artifacts and test runner have not been migrated by that change. This phase remains Active until the tooling tasks and actual acceptance/mutation evidence below pass. The next implementation session starts here, not at the historical decimal-sprint queue.

The [documentation adoption verification](evidence/documentation_adoption.md) records structural checks and the actual unchanged doc-lint failure. It does not close A00/M00. The first observed mismatch is the old generated resource-lifecycle marker in `substrates.md`; audit all old hardcoded assumptions during P00-T01.

## Implementation tasks

- [ ] **P00-T01** — Update the existing Haskell document/plan checker and its tests to parse the canonical Markdown manifests, numbered phase records and snake_case ledger. Preserve legacy-source discovery only where the migration ledger requires it; remove hardcoded old queue/filename/table assumptions.
- [ ] **P00-T02** — Expand and mechanically reconcile every current public/internal command leaf and meaningful option against command_dispositions.md. Reconcile every product objective, old open obligation and pending/unowned legacy row; do not carry historical Done labels as new evidence.
- [ ] **P00-T03** — Implement real invalid-plan fixture tests for future dependency, command omission, broken link, missing evidence binding and invalid removal owner. Include source/test existence checks and evidence availability without treating a string-shaped claim as execution.
- [ ] **P00-T04** — Build safe scratch variants for M00 using existing tooling, compile the actual changed checker and require the intended unchanged assertions to fail. The automated runner in Phase 1 is not a prerequisite.
- [ ] **P00-T05** — Run the canonical gate and actual Phase-0 checker acceptance; record source/binary identity, negative-control outcomes, mutation outcomes and owned removal proofs. Retire the temporary hyphenated ledger forwarding document only when code no longer depends on it.

## Real acceptance and independent observation

After implementing the checker migration, build the operator with the repository Cabal build path and invoke the real `./.build/prodbox dev check`. Run the actual checker fixtures and scratch source variants using existing compiler/test entrypoints. Do not wait for Phase 1 automation or substitute a Markdown review for execution.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A00-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A00-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A00-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A00-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M00 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

No runtime/provider resources are admitted. Work uses non-secret owned scratch copies and bounded compiler/test outputs; preserve only evidence inputs still needed to reproduce results.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/documentation_standards.md](../documents/documentation_standards.md)
- [DEVELOPMENT_PLAN/development_plan_standards.md](development_plan_standards.md)
- [documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [documents/engineering/code_quality.md](../documents/engineering/code_quality.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [ ] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [ ] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

All four acceptance cases and M00 pass on the actual revised tooling; every active command/objective/removal has one valid owner; no future phase is needed to understand or enforce this plan.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
