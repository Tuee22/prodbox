# Phase 05: First Complete AWS Resource Lifecycle

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: A cheap real owned cloud family can be created, used, interrupted, recovered and deleted through the same public engine, with observer sensitivity proven independently.

**Phase**: 5
**State**: Planned
**Prerequisites**: Phase 4 complete; same real account/region and fixed small resource/spend budget. No EKS, SES or public DNS is required.
**Acceptance**: A05-01, A05-02, A05-03, A05-04, A05-05 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M07, M08 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L11 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B015, B047, B062, B063, B064, B081 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

A cheap real owned cloud family can be created, used, interrupted, recovered and deleted through the same public engine, with observer sensitivity proven independently.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P05-T01** — Implement the explicit storage-canary adapter: one exact owned S3 bucket with versioned test objects and delete markers, separate from the legacy three-EC2 aws-test stack. Register its names/tags/ownership and recovery obligations before effects; expose the scoped `admin aws stack storage-canary reconcile/delete` handlers as peer clients of the common engine.
- [ ] **P05-T02** — Implement service-specific resource inventory with declared scope and positive control, checkpoint-independent recovery, partial create, lost reply and independent post-delete read-back.
- [ ] **P05-T03** — Extend ordinary delete and the credential tail to the introduced family; commit the local terminal/recovery record before deleting remote stores and their write authority.
- [ ] **P05-T04** — Implement scoped admin AWS policy/quota inspection, configured quota request/status and digest-bound recovery plan/apply for the delivered family. Only closed actions are allowed; no generic admin/provider passthrough.
- [ ] **P05-T05** — Run actual create/use/delete/repeat and interrupted/corrupt-checkpoint/denied-inventory/residue cases. Complete two consecutive audit-clean cycles under one declared build within the campaign protocol.
- [ ] **P05-T06** — Kill M07/M08 using recorded provider-boundary fixtures and unchanged assertions, then separately run real unmodified provider scenarios. Retire this family’s old provider and harness cleanup dispatch.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-05`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A05-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A05-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A05-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A05-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A05-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M07, M08 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

The exact storage-canary S3 bucket, objects/versions/delete markers, scoped credential generations and quota/recovery requests. The legacy three-EC2 test stack is not created or required by this phase. Clean all introduced families and observe terminal absence; an approved quota request is recorded distinctly from deployed-resource absence.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/aws_resources.md](../documents/engineering/aws_resources.md)
- [documents/engineering/lifecycle.md](../documents/engineering/lifecycle.md)
- [documents/engineering/security_and_credentials.md](../documents/engineering/security_and_credentials.md)
- [documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [ ] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [ ] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

Real cloud creation/recovery/deletion and ordinary repeat no-op work with independent inventory and credentials retired. A later EKS adapter neither supplies nor blocks this proof.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
