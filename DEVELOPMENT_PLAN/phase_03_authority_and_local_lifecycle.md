# Phase 03: Retained Authority and Shared Local Lifecycle

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: One retained Authority drives public status/plan/delete/resume. A never-admitted deployment deletes as a truthful no-op while management survives, and missing existing history cannot be relabeled fresh.

**Phase**: 3
**State**: Planned
**Prerequisites**: Phases 1–2 complete. No AWS account/domain, remote backup bucket, EKS or future cloud adapter is required.
**Acceptance**: A03-01, A03-02, A03-03, A03-04, A03-05, A03-06 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M04, M05 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L08, L09 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B018, B022, B029, B042, B049, B050, B051, B057, B058, B059, B060, B066, B074, B077 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

One retained Authority drives public status/plan/delete/resume. A never-admitted deployment deletes as a truthful no-op while management survives, and missing existing history cannot be relabeled fresh.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P03-T01** — Implement the actual durable Authority journal, public non-secret metadata projection, local backup/restore and validated operation identity. Host bootstrap metadata locates the Authority but is not a competing cloud-state writer.
- [ ] **P03-T02** — Implement shared observe/plan/execute/read-back and operation recovery across CLI/test/maintenance. Keep resource truth, checkpoint usability, credential state and audit evidence distinct; register intent before any future cloud effect can be authorized.
- [ ] **P03-T03** — Activate public delete/status/plan/operations resume for delivered scopes. A never-admitted delete does not call AWS or initialize Vault. An unresolved journal or stale projection cannot license NoChange or mutation.
- [ ] **P03-T04** — Implement obligation-aware control removal and exact test-root cleanup separately from AWS deletion. Preserve required management plane and evidence for pending/unknown cloud obligations.
- [ ] **P03-T05** — Implement advanced audited unlock-bundle/Transit rotation, PKI status/real issuance and bounded ambiguous-init recovery using the retained journal. Bind confirmation to original scope/generation; refuse stale/missing evidence rather than overwrite retained data.
- [ ] **P03-T06** — Run real crash/restart/concurrency/resume, missing/corrupt journal, sealed/unreachable component, no-op and advanced Vault cases. Remove cascade from the new active surface; route any original-install cleanup only through the ledger-bound migration lane.

Fresh admission-history reads authenticate through local/control identity without Vault login/Transit; prove same-Authority metadata startup and read while Vault is sealed. Secret/provider effects remain unavailable without their normal capabilities. A stale projection cannot supply NeverAdmitted.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-03`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A03-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-06** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M04, M05 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Authority journal and metadata, local backup, advanced Vault key/certificate generations and exact operation records. Preserve management trust, unresolved recovery material and bounded completion reports. No cloud resource family is claimed before its implementation phase.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/lifecycle.md](../documents/engineering/lifecycle.md)
- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
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

Actual public local/never-admitted and advanced Vault workflows pass, one durable writer survives restart, and all owned legacy routes are retired without depending on later AWS implementation.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
