# Phase 02: Real Vault, MinIO, and Bootstrap Recovery

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: Actual Vault/MinIO/Broker services boot and recover from retained artifacts; test-only MinIO self-unseal and protected production unlock behave distinctly and preserve the same Vault identity.

**Phase**: 2
**State**: Planned
**Prerequisites**: Phase 1 complete. No registry service, AWS, public DNS, SES, application platform or later Authority implementation is needed for this bootstrap-owned scope.
**Acceptance**: A02-01, A02-02, A02-03, A02-04, A02-05 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M03 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L06, L07 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B026, B041, B053, B054 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

Actual Vault/MinIO/Broker services boot and recover from retained artifacts; test-only MinIO self-unseal and protected production unlock behave distinctly and preserve the same Vault identity.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P02-T01** — Deploy real MinIO, Vault, Bootstrap Broker and bounded workers from exact pinned local artifacts, independent of the registry and public edge they may later support.
- [ ] **P02-T02** — Separate bootstrap MinIO access from steady-state Vault-backed MinIO policy. Define the exact pre-Vault read capability for the test run’s unlock object; never rely on the sealed Vault to decrypt its only unlock key.
- [ ] **P02-T03** — Implement explicit protected production and test MinIO self-unseal policies. Expose actual direct component status while Broker/Vault/MinIO availability differs. Production cannot load the test policy.
- [ ] **P02-T04** — Implement init/unseal/baseline, retained-generation checks, bounded interruption continuation and local backup/restore for this scope. Do not reinitialize over missing/corrupt/foreign retained identity; report the exact data-loss/recovery condition.
- [ ] **P02-T05** — Exercise actual policy traffic and actual concurrent secret workers within Phase 1’s capacity reservation. Observe workload settlement or durable recoverable ownership on every failure/cancellation.
- [ ] **P02-T06** — Run secret round-trips, real seal/unseal, wrong input/missing custody/outage cases, kind recreation, direct status and M03. Explicit audited Authority-mediated rotation/PKI/reset features belong to Phase 3 and are not a bootstrap closure dependency.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-02`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A02-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A02-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A02-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A02-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A02-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M03 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Real management namespaces/PVs, test unlock object/access material and short-lived workers. Never persist AWS elevated input here. Exact test cleanup retires run-owned unlock material and workers after their dependencies settle; production retained volumes are not erased.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/security_and_credentials.md](../documents/engineering/security_and_credentials.md)
- [documents/engineering/configuration.md](../documents/engineering/configuration.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [ ] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [ ] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

All advertised bootstrap cases pass against actual services, original Vault data survives kind recreation, policies and capacity are observed, and no future cloud/Authority adapter substitutes for required evidence.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
