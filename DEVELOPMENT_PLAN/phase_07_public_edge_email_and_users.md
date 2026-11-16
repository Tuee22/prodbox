# Phase 07: Real Public Edge, Email, and User Journeys

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: Local kind applications serve real DNS/TLS/auth/email journeys, production and test email ownership remain separate, and ordinary delete covers every introduced cloud family.

**Phase**: 7
**State**: Planned
**Prerequisites**: Phase 6 complete and existing IAM/provider capability; real domain/parent-zone inputs, ZeroSSL/ACME material, SES prerequisites and declared quota/spend budgets.
**Acceptance**: A07-01, A07-02, A07-03, A07-04, A07-05 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M10 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L13 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B014, B019, B031, B033, B034, B035, B040, B065, B076 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

Local kind applications serve real DNS/TLS/auth/email journeys, production and test email ownership remain separate, and ordinary delete covers every introduced cloud family.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P07-T01** — Implement real managed DNS/subzones where needed, ZeroSSL DNS01 issuance/retention/restore/rotation, SES send/receive/capture, user invite/list/revoke and public Keycloak/API/websocket authorization.
- [ ] **P07-T02** — Bind test sender/receiver identities, SMTP credentials, capture bucket/prefixes, DNS and owned receipt rules to the exact test campaign. Do not reuse production SES. Reuse across cases is allowed only within that campaign’s explicit owner.
- [ ] **P07-T03** — Coordinate the shared-account regional active SES receipt-rule-set container explicitly. Test setup/cleanup may add/remove only its owned rules; it cannot switch/deactivate production receiving, erase foreign rules or silently require a dedicated account.
- [ ] **P07-T04** — Implement any optional remote Authority-backup adapter here, with encrypted objects/versions, bucket and IAM ownership plus real restore and default-delete behavior before Phase 8’s complete AWS claim.
- [ ] **P07-T05** — Extend common create/observe/recover/delete and credential retirement for DNS, SES, S3/TLS/backup and user-related families in this phase. Quiesce cloud-dependent local consumers before removing credentials; report inactive public features accurately.
- [ ] **P07-T06** — Run independent public DNS/TLS/auth and real email/receipt/user revocation, failed issuance/lost-reply/restore cases, simultaneous isolated test/production-policy campaigns and exact cleanup/reconcile. Kill M10 offline, including foreign receipt-rule protection.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-07`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A07-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A07-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A07-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A07-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A07-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M10 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Owned Route53 records/subzones, SES identities/rules/SMTP IAM, capture objects/buckets, TLS/backup remote objects/versions and credential generations. Preserve external account/domain/parent zone and foreign receipt rules; after exact cloud cleanup retain kind and local report.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/public_edge.md](../documents/engineering/public_edge.md)
- [documents/engineering/aws_resources.md](../documents/engineering/aws_resources.md)
- [documents/engineering/security_and_credentials.md](../documents/engineering/security_and_credentials.md)
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

Real public local application journeys and all cloud support-family cleanup pass. Test SES stays distinct from production, shared-account receiving is protected, and EKS is not needed for closure.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
