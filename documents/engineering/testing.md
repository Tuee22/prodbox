# Testing and Evidence

**Status**: Authoritative source
**Supersedes**: Pre-refactor unit, integration-fixture and test-topology doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; evidence/tooling migration is still open in Phase 0

> **Purpose**: Define one isolated test runner, real acceptance evidence and bounded source-mutation gates.

## One runner and claim boundary

`test run NAME` selects a typed scenario from one registry; unit, CLI, integration, mutation, fault and aggregate scenarios share context/evidence/cleanup ownership. The harness drives the actual public production implementation. No second install/provision/cleanup implementation can pass while the operator command remains broken.

The named `unit`, `env`, `cli`, and `evidence` routes select existing local
test suites. The `phase-01` route is under active development: it prepares a
fresh test identity and pinned inputs, then drives the Phase 1 scenario; its
automatic preparation and real lifecycle have not yet completed acceptance.
The CLI suite contains legacy lifecycle fixtures and refuses to start
when an RKE2 installation marker exists or cannot be observed. The local routes
refuse unsupported coverage and AWS-substrate options and use a limited child
environment; that environment is not an operating-system sandbox. `test list`
reports these built-in local routes and identifies topology-defined suites as a
separate legacy source; it does not yet list the complete target scenario catalog.
`test status RUN_ID` currently reads retained local mutation-campaign records
for that exact run. It reports incomplete because Docker state, worker
settlement and workspace cleanup are not yet observed by that path; it does
not remove resources or establish a successful test result. A self-consistent
retained launch may differ from the current command; status reports that
difference without claiming to authenticate the historical source.
New mutation campaigns also retain a source-bound creation record before any
snapshot or container request. Status identifies a missing, unsafe or mismatched
record as incomplete; the record does not establish worker or resource absence.

Every acceptance case declares input/context, scope, real prerequisites, allowed resources, commands, expected observations, adverse cases, cleanup, numerical owner and artifact identity. Tests may use completed earlier phases and external prerequisites, never an unimplemented later feature hidden behind a fake. Planned/skipped later cases do not count as passed. [Cases](../../DEVELOPMENT_PLAN/acceptance_cases.md)

Pure unit/property/protocol tests remain useful. Mock at interpreter/subprocess boundaries rather than inside the decision being tested. They do not close a real-provider, physical-worker, public TLS or persistence claim. The final campaign repeats already proven public slices; it is not their first real composition test.

## Fixture and environment isolation

Keep authored `prodbox.test.dhall`, owner-safe `test-secrets.dhall`, and per-run generated `prodbox.dhall` distinct. The harness uses the production builder and explicit run file without rewriting the production sibling. Test elevated input simulates the real prompt→Provisioner path and is not pre-provisioned operational auth.

Each run owns `.test-data/<run-id>`, kind/context/ports, Vault/MinIO namespaces, cloud names/tags and exact cleanup. Production `.data`, credentials, SES/DNS/email capture and existing deployments are outside its authority. Detect overlap/collision before effects; failed cleanup leaves a resumable owned run.

Production-policy cases use an isolated project anchor owned beneath the test run and its own `.data/<id>`, normal production-policy CLI and a driven real protected prompt. They never point at the operator's root or set a production-bypass flag. Test MinIO self-unseal is separately tested and rejected by production policy.

## Registration, cleanup and results

Register every resource, generated config/artifact and credential obligation before creation. Use the same Authority operation and exact desired-absence adapters as production. Cleanup runs on success/failure/cancellation and preserves the primary failure plus each independent cleanup result. Scheduling a cleanup callback is not resource absence.

A real run passes only after all required resource/state/credential read-backs. No manual/ad-hoc resource mutation or cleanup counts toward qualification. An authorized hand action is recorded and turned into a planted offline case; it never becomes a product success receipt.

Independent observers verify actual consequences, not the executor's success string. They carry exact context/field/query results and fail when a required query or positive control is unavailable. Include deliberate wrong-account/region/identity/host, missing observation, denied action and retained-resource controls. A service Ready flag or copied receipt cannot replace observation.

## Evidence

Bind scenario/case, source-manifest policy and digest, binary/image identity, non-secret config projection, environment/deployment/operation, selected commands, timestamps/durations, primary and cleanup outcomes and independent observations. Do not hash or log plaintext secrets, environment credentials, fixture contents or private keys. Secret-dependent facts use opaque generation/receipt references.

An evidence artifact needs a retained location and availability manifest. State its actual source/topology/load/fault scope and practical limits. Old source/test receipts remain historical, not current closure. Tests that no longer exist cannot support an active claim. Repeat the required complete clean cycles before soak; two cycles are an entry criterion rather than a guarantee of reliability.

## Targeted mutation testing

Source mutation means deliberately changing the implementation while leaving its selected tests unchanged. It differs from bad inputs, injected outages and AWS/Kubernetes mutations. Use the [critical catalog](../../DEVELOPMENT_PLAN/mutation_cases.md), a small reviewed semantic set plus bounded selection around changed critical code; no repository-wide percentage target.

1. Pass the unmodified baseline under the same tests/toolchain/dependencies.
2. Apply one exact named patch in an isolated non-secret snapshot with separate build output. Refuse stale/missing patch sites. Never overwrite the operator binary, working source, production data or test assertions.
3. Execute the actual mutated implementation and require the named invariant's unchanged assertion to fail. For observer/runner mutants, keep the independent meta-test unchanged.
4. Record `Killed`, `Survived`, `Invalid`, `Inconclusive` or `Equivalent`. Only the intended behavioral assertion failure is a kill. Compile/typecheck errors are Invalid; unrelated failures/outages/timeouts are Inconclusive. Silence or process exit alone is not a kill.
5. A surviving non-equivalent critical fault blocks closure. An equivalence exclusion needs source/contract-bound reviewed reasoning; invalid/inconclusive/skipped runs cannot satisfy a required case. Re-run affected cases when implementation, tests, observer or patch changes.

Record baseline/patch/test/assertion identities, actual failure, budget/duration and cleanup. Critical faults include unknown→absent, missing environment checks, fabricated Clean, skipped deletion/read-back, early credential retirement, absent write-ahead intent and competing migration writers.

Dangerous cloud/ownership mutants run offline against recorded provider contracts and pure/interpreter-boundary tests. Enforce isolation with process/container boundaries: no AWS credentials/test-secrets, current kubeconfig, host roots, unrestricted container socket, publication credentials or route to real provider APIs. Unmodified outer ownership may lend an exact disposable local fixture interface; mutant code cannot certify its own safety or cleanup.

All real AWS/public-edge qualification uses a separately identified unmodified build. Mutation results prove detection of seeded faults, not provider behavior. Phase 0 exercises checker mutations with existing scratch/build tooling; Phase 1 automates the bounded runner and proves killed/surviving/invalid/inconclusive classification. Later phases add only current/prior capabilities. Do not create a second general testing framework.

## Phase closure

A phase closes only after its real public cases, expected mutation failures, cleanup, documentation and owned removals pass. Missing external credentials/provider readiness may block the phase that needs them; incomplete later implementation cannot. The [development standards](../../DEVELOPMENT_PLAN/development_plan_standards.md) own queue and closure mechanics.

## Implemented through Phase 1

`prodbox test run phase-01` drives the public binary through two lifecycles on one retained root and publishes independently validated scenario reports under `<project>/.build/scenario-evidence/<run>/` (a private `.build` is required); claimed observations come from the public commands' own output and independent observations from direct reads, Docker and kubectl. `prodbox test run phase-01-mutation` snapshots the secret-filtered worktree into a no-network container, builds a baseline and a mutant, runs one designated test and classifies it Killed, Survived, Invalid or Inconclusive. Evidence and limits: [Phase 1 validation](../../DEVELOPMENT_PLAN/evidence/phase_01_validation.md).

## Implemented through Phase 2

`prodbox test run phase-02` runs eight cases (initialize, self-unseal, protected unlock including a real pseudo-terminal prompt, concurrent workers with policy allow/deny traffic and the no-registry check, backup/restore, Broker outage, adverse controls, recreation) and `test run phase-02-broker` runs the Broker-mediated cases; each records independent observations without secret values. The mutation catalog covers M01, M02, M03a and M03b with calibration controls and is re-run whenever the pinned `Unlock.hs` changes. Observation lists must stay the same length as their claim lists because the comparison pairs them positionally.
