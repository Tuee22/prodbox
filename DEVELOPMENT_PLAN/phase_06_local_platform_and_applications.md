# Phase 06: Local Platform, Applications, and Image Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: The canonical service catalog runs on local kind with real protocols, persistent data, uncached image delivery and protected management scope.

**Phase**: 6
**State**: Planned
**Prerequisites**: Phase 5 complete; pinned local images and declared host capacity. Local application proof does not require a public domain/ACME/SES or EKS.
**Acceptance**: A06-01, A06-02, A06-03, A06-04, A06-05, A06-06, A06-07 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M09 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L12 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B017, B024, B027, B044, B061, B067, B068 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

The canonical service catalog runs on local kind with real protocols, persistent data, uncached image delivery and protected management scope.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

- [ ] **P06-T01** — Deploy gateway, Keycloak and its PostgreSQL, VS Code, API, Redis, websocket, MinIO, registry:2, Percona operator, MetalLB, Envoy Gateway, cert-manager and retained Pulsar broker/client/topic behavior from one typed catalog.
- [ ] **P06-T02** — Implement actual node registry mirrors and image publication/retention. Preserve bootstrap independence; prove host/node/Pod loopback resolution through uncached pulls rather than cached startup.
- [ ] **P06-T03** — Implement the fixed MetalLB kind-network pool and explicit host ingress mappings into Envoy. Observe Docker-network, host and intended LAN connectivity; do not inherit RKE2 LAN assumptions.
- [ ] **P06-T04** — Extend real resource governance and NetworkPolicy from management to the complete application projection, including simultaneous transient workers, actual persistence and service readiness.
- [ ] **P06-T05** — Expose services diagnostics and component desired-state reconcile/delete through shared handlers. Deletion changes the selected specification atomically so ordinary reconcile does not recreate it; temporary stop/restart is explicit.
- [ ] **P06-T06** — Exercise real SQL/object/auth/API/Redis/websocket/VS Code/Pulsar interactions, failure/recovery, data through node recreation, full load, gateway role configuration and M09. Ordinary cloud delete retains and reports local scope accurately.

Gateway config generation is delivered through `dev config gateway OUTPUT_PATH` in this phase, using the same validated context and role-config builder; Phase 9 only extends fault/reload scope.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-06`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [ ] **A06-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A06-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A06-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A06-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A06-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

- [ ] **A06-06** — execute the public gateway config generator and independently compare its non-secret projection with the actual mounted/runtime configuration.

- [ ] **A06-07** — execute the cataloged fixed/bounded scaling, real count read-back and capacity/quota rejection case; do not claim an unwired autonomous controller.

## Critical source mutations

Run M09 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Application namespaces, local PVs, registry images, messaging topics and actual publication/network resources. Component cleanup preserves management and pending-cloud capabilities. Whole disposable test environment cleanup follows proven cloud retirement; production local data is not ordinary AWS delete scope.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/platform_and_services.md](../documents/engineering/platform_and_services.md)
- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/gateway_and_messaging.md](../documents/engineering/gateway_and_messaging.md)
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

The full local projection passes real protocol/storage/isolation/capacity assertions and its component controls. Later EKS work reuses the catalog instead of replacing its semantics.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
