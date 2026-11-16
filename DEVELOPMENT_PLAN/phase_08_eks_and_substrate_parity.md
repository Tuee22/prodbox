# Phase 08: EKS, Static EBS, and Substrate Parity

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: The EKS target runs the same application projection under retained local kind authority, and ordinary delete removes every supported owned AWS family with independent evidence.

**Phase**: 8
**State**: Planned
**Prerequisites**: Phase 7 complete; actual EKS/service quotas and declared live budget. Reuse existing credentials, journal, catalog and observers; do not introduce another auth architecture.
**Acceptance**: A08-01, A08-02, A08-03, A08-04, A08-05, A08-06 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M11 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L14, L15, L16 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B030, B036, B038, B043, B045, B046, B052, B056, B075, B079, B080 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

The EKS target runs the same application projection under retained local kind authority, and ordinary delete removes every supported owned AWS family with independent evidence.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P08-T01** — Implement EKS/VPC/node-group/IAM/subzone, static EBS, registry mirror, AWS Load Balancer Controller and canonical service projection as adapters of the established model.
- [ ] **P08-T02** — Observe exact EKS identity before creating a scoped drain session. Register controller-created network/dependent families and DNS/certificate consumers before activation; unrelated stack state cannot choose a target.
- [ ] **P08-T03** — Implement dependency-ordered deletion/backstops for cluster/nodes/load balancers/CNI interfaces/security groups/NAT/endpoints/subnets/VPC/EBS and prior owned DNS/SES/storage/IAM families.
- [ ] **P08-T04** — Expose scoped stack status/diff and digest-bound recovery for the delivered adapters. Checkpoint loss and known legacy shape use exact approved ownership evidence, not a tag sweep as destroy permission.
- [ ] **P08-T05** — Run actual service parity, external DNS/TLS/auth, static rebind, interrupted create before checkpoint commit, late dependents, unavailable drain/stalled delete, wrong scope and repeat cleanup. Complete the required consecutive audit-clean cycles with kind still live.
- [ ] **P08-T06** — Retire ordinary/new-deployment bespoke cascade/no-install/nuke/reaper routes and generated flags after replacement acceptance. Enumerate any exact original-install-only code under L18 for Phase 10 rather than deleting its necessary cleanup early. Kill M11 offline.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-08`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A08-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A08-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A08-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A08-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A08-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

- [ ] **A08-06** — execute the cataloged fixed/bounded scaling, real count read-back and capacity/quota rejection case; do not claim an unwired autonomous controller.

## Critical source mutations

Run M11 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

All registered EKS/EC2/EBS/network/DNS/storage/IAM families and controller dependants. Delete owns production-retained as well as test volumes under its explicit destructive confirmation contract. Never force unrelated/requester-managed objects; preserve bounded report and recovery credentials if any family is unresolved.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/aws_resources.md](../documents/engineering/aws_resources.md)
- [documents/engineering/platform_and_services.md](../documents/engineering/platform_and_services.md)
- [documents/engineering/lifecycle.md](../documents/engineering/lifecycle.md)
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

Actual AWS application parity and full ordinary delete/repeat pass; no normal user reaper/cascade duty remains. Exact old-install migration residue is separately owned and cannot serve new ordinary deployments.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
