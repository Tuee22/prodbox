# Phase 09: HA, Federation, and Recovery Guarantees

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: Real gateway failover, worker settlement, federation and retained recovery guarantees extend the same lifecycle engine without changing command, root or deletion semantics.

**Phase**: 9
**State**: Planned
**Prerequisites**: Phase 8 complete with actual local/EKS services. Remote backup lifecycle is already implemented/cleanable in Phase 7.
**Acceptance**: A09-01, A09-02, A09-03, A09-04, A09-05 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M12 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L17, L21 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B013, B025 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

Real gateway failover, worker settlement, federation and retained recovery guarantees extend the same lifecycle engine without changing command, root or deletion semantics.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P09-T01** — Preserve gateway leader/emitter continuity, bounded journals, role-config generation/reload and multi-node kind/EKS failover assertions. Describe the actual failure domain; kind node loss is not a multi-machine/AZ proof.
- [ ] **P09-T02** — Implement explicit federation registration/status, child trust/custody/recovery and stale/replayed identity rejection with one owner per deployment scope.
- [ ] **P09-T03** — Exercise local and prior remote backup crash restoration, Authority/worker loss, held/delayed requests, concurrent duplicates, cancellation and response loss.
- [ ] **P09-T04** — Require actual predecessor workload settlement/ownership before successor effects. Wall-clock expiry is not physical absence; avoid extra distributed/time-trust machinery unless a retained acceptance case demonstrates the need.
- [ ] **P09-T05** — Run real controlled network/process/node failures with independent observers and cleanup. Add default-delete/read-back cases for any newly discovered owned resource family before closure.
- [ ] **P09-T06** — Retire HA-RKE2-specific provisioner/suite and obsolete protocol/formal-model variants only after the preserved behavior passes on kind/EKS. Kill M12 offline.

Integrate useful `Scaling/Autoscaler` trust-tree/leader constraints into the explicit validated reconciler or remove their unwired facade under L21. Existing pure planning is not proof of a running background controller.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-09`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A09-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A09-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A09-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A09-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A09-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M12 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Gateway/federation test children, exact worker attempts, journal/backup fixtures and bounded network fault resources. Preserve immutable identity and necessary custody until independent retirement; restore normal connectivity and prove each owned cloud/local family clean.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/gateway_and_messaging.md](../documents/engineering/gateway_and_messaging.md)
- [documents/engineering/federation.md](../documents/engineering/federation.md)
- [documents/engineering/lifecycle.md](../documents/engineering/lifecycle.md)
- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [ ] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [ ] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

Each retained HA/federation/recovery claim has real fault, settlement and cleanup evidence. No later migration phase is needed to make new-deployment behavior usable.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
