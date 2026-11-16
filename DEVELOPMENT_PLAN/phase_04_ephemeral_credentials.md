# Phase 04: Real Ephemeral Admin and Operational Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: The operator prompt and test simulator use the same real Provisioner workflow to create, use and retire least-privilege prodbox credentials without persisting elevated input.

**Phase**: 4
**State**: Planned
**Prerequisites**: Phase 3 complete; declared real test AWS account, allowed region, explicit spend/time budgets and owner-safe test-secrets.dhall fixture. These are external inputs, not later product deliverables.
**Acceptance**: A04-01, A04-02, A04-03, A04-04, A04-05 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M06 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L10 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B016, B023, B028, B037, B078 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

The operator prompt and test simulator use the same real Provisioner workflow to create, use and retire least-privilege prodbox credentials without persisting elevated input.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P04-T01** — Implement one ephemeral elevated ingress for the real protected operator prompt and the test fixture’s simulation. Validate the owned no-follow regular file descriptor and 0600 mode without exposing its bytes.
- [ ] **P04-T02** — Commit exact IAM-family intent before the first possible elevated AWS mutation. Implement the bounded Provisioner and scoped role/session policy; reject ambient AWS profiles/environment credentials and fixture-to-production config copying.
- [ ] **P04-T03** — Deliver generated operational material to real Vault under exact deployment/generation identity. Keep elevated bytes out of Vault/MinIO/config/Kubernetes objects/argv/environment/logs/evidence.
- [ ] **P04-T04** — Extend ordinary delete to this first AWS resource family: settle dependants, remove generated IAM keys/principals/policies, independently verify final absence using the still-available ephemeral verifier, then retire Vault generations.
- [ ] **P04-T05** — Implement restart and applied-but-response-lost recovery with re-prompt/fixture reacquisition for the same journaled operation. Preserve needed credential capability until all dependants are terminal.
- [ ] **P04-T06** — Run real IAM/STS/Vault allow/deny/use/retirement, interruption, malformed fixture, redaction and actual supported token lifecycle checks under real management-plus-worker load. Kill M06 only offline.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-04`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A04-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A04-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A04-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A04-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A04-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M06 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Real generated IAM identities/keys/roles/policies, short operation sessions, Vault generations and worker workloads. Record and observe resource-before-IAM-before-Vault retirement. Preserve the operator-owned bootstrap principal/credential and external account; incomplete cleanup remains resumable.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/security_and_credentials.md](../documents/engineering/security_and_credentials.md)
- [documents/engineering/lifecycle.md](../documents/engineering/lifecycle.md)
- [documents/engineering/aws_resources.md](../documents/engineering/aws_resources.md)
- [documents/engineering/resource_governance.md](../documents/engineering/resource_governance.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [ ] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [ ] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

The actual credential family completes create/use/restart/recover/delete with independent IAM and Vault absence. No elevated runtime persistence or future EKS dependency remains.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
