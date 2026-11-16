# Phase 01: CLI Contexts, Retained kind Storage, and Evidence

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: The real public control/context slice creates and diagnoses isolated kind environments whose host-backed data survives node loss, and a bounded evidence/mutation runner detects fabricated results.

**Phase**: 1
**State**: Planned
**Prerequisites**: Phase 0 complete; supported Linux host and pinned container-runtime/kind prerequisites. No Vault, cloud account, SES, public domain, or later runtime adapter is required.
**Acceptance**: A01-01, A01-02, A01-03, A01-04, A01-05, A01-06, A01-07 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M00, M01, M02 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L04, L05 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B020, B021, B039, B055 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

The real public control/context slice creates and diagnoses isolated kind environments whose host-backed data survives node loss, and a bounded evidence/mutation runner detects fabricated results.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P01-T01** — Refactor the typed CommandSpec/parser/dispatch boundaries and visibility model. Add explicit --config, minimal bootstrap context and scoped diagnostics; activate only completed commands, without successful future-feature stubs.
- [ ] **P01-T02** — Implement production/test identity and safe path construction: distinct project roots, kind names, mounts, kubeconfigs, ports, networks, metadata and resource ownership. Reject overlap, symlink escape, foreign context and ambient target selection before effects.
- [ ] **P01-T03** — Implement the kind adapter with exact host extraMounts, deterministic PV binding, pinned node/bootstrap artifact identity and explicit node port reservations for the accepted MetalLB/Envoy publication contract. Existing RKE2 identity import is not new enrollment.
- [ ] **P01-T04** — Implement management CNI policy enforcement and host/node capacity discovery, real requests/limits/quotas and a funded simultaneous management/secret-worker envelope before later secrets work.
- [ ] **P01-T05** — Implement the common real scenario/evidence runner, independent evidence validator and bounded source-mutation executor. Bind outcomes to actual source/build/test identity; distinguish detected, surviving, invalid and inconclusive calibration faults.
- [ ] **P01-T06** — Activate early control removal only for exact new identities that cannot have admitted cloud effects. Foreign/existing/unknown identities refuse; do not bypass Phase-3 obligation semantics.
- [ ] **P01-T07** — Run real kind recreation, cross-environment negative controls, allow/deny connections, capacity worker completion, evidence/mutation calibration and outer cleanup. Re-run M00 through the new automation.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-01`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A01-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A01-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A01-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A01-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A01-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A01-06** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A01-07** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M00, M01, M02 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Two real disposable kind environments, owned host volumes, ports/networks and marker Pods. Cleanup uses exact identities; preserve original host markers through node recreation, then remove only the run-owned disposable scope. Mutation children lack production roots, provider credentials, current kubeconfig and unrestricted runtime/publication access.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/configuration.md](../documents/engineering/configuration.md)
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

Real kind/control/context behavior and the evidence/mutation runner pass all owned cases. Cloud admission is impossible; storage retention and actual management isolation/capacity are proven before secret workers are introduced.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
