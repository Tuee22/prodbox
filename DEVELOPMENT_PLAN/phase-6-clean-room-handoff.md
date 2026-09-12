# Phase 6: Final Clean-Room Rerun and Zero-Python Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Capture the zero-Python handoff criteria: a full clean-room rerun through the
> Haskell stack and a cleanup ledger where any surviving supported-path residue is explicitly
> owned by its originating phase.

## Phase Status

🔄 **Reopened and active on Sprint `6.5` (Standards A/L/P).** Sprints `4.86`, `4.89`, `5.36`,
`7.36`, and `7.38` have completed the replacement program, custody disposition, validation client,
exact AWS adapters, and compiled DNS-zone binding this cutover consumes. Phase 6 owns the
generic/home single-writer cutover, installed-binary clean-room handoff, rollback rule, and
legacy-absence proof for the replacement teardown. The prior clean-room proof exercised the
superseded cascade and cannot qualify this production-composition change. Deployment qualification
remains pending.

✅ **Reclosed 2026-08-02 on Sprint `6.4`.** The clean-room handoff covers authority-epoch
migration, restart-resume behavior, rollback refusal after cutover, complete home restoration, and
zero surviving legacy gateway authority routes. The June 26 run remains historical proof of its
then-current topology; current-revision live qualification remains pending under Standards O/P.

🧾 **Historical live evidence from 2026-06-26 (home substrate).** The then-current home
`prodbox test all` reported 18/18 (see [00-overview.md → Historical Alignment Record](00-overview.md#historical-alignment-record)), exercised
`cluster delete` → `cluster reconcile` → `cluster health`, and reported successful provider destroy
and residue-check results for the per-run AWS stacks. That is command/provider/residue-check evidence
for the superseded topology, not independent exact absence evidence for every registered stack and
resource family; it therefore does not prove “no leaked AWS spend” or qualify the replacement
teardown. The `--substrate aws` rerun coverage remains the orthogonal, non-blocking axis
([substrates.md](substrates.md)).

✅ **Historical narrower surfaces remain done** — Sprints `6.1`–`6.3` remain closed on the destructive rerun
contract and zero-Python handoff surfaces. Per
[development_plan_standards.md](development_plan_standards.md) standards rules E and N, Phase 6
retains those results independently of later phases. They do not prevent the phase from being
reopened when Sprint `6.4` explicitly expands Phase 6's own authority-migration and clean-room
surface. Sprint `5.19` subsequently closed and Sprint `6.4` completed the expanded surface.

**Independent Validation** (Standard N): Phase 6 is validatable on its owned surface — the
destructive clean-room rerun contract, the zero-Python repository handoff, and the single-host
handoff criteria — with no dependency on a later phase. The owned-surface proof runs on the
home/local substrate through `prodbox test all`, `prodbox config show`, `prodbox config validate`,
and `prodbox edge status`, plus `prodbox dev check` and `prodbox test unit` and the
repository artifact/text-search closures plus Sprint `6.4`'s versioned fake migration/cutover,
interruption, rollback-refusal, and route-absence fixtures; where the rerun composes deliverables owned by earlier
phases it exercises them against the home/local substrate. AWS-substrate coverage of the rerun is
tracked in [substrates.md](substrates.md)'s parity table, and any proof needing live
infrastructure (live AWS spend, deployed cluster, unsealed Vault, operator-supplied credential) is
a non-blocking `Live-proof: pending` note per Standard O rather than a gate on phase closure.

## Phase Summary

This phase defines the clean-room and zero-Python handoff criteria for the Haskell-only repository.
Its current work is Sprint `6.5`: activate the Sprint-`4.86` replacement as the sole public
generic/home teardown writer, prove the indexed rollback/cutover boundary, and remove the legacy
generic/home route. It is blocked only by earlier-phase Sprints `4.86` and `5.36`.

Sprints `6.1`–`6.4` remain closed on their historical repository-owned rerun, zero-Python,
single-host, and authority-migration surfaces. Their older clean-room evidence exercised the
superseded cascade and is not current deployment qualification. Phase 7 Sprint `7.36` separately
owns the exact AWS adapter and removal of checkpoint-derived EKS access; Phase 6 neither depends on
that later work nor claims AWS adapter parity.

## Current Baseline In Worktree

- The destructive rerun proof runs entirely through Haskell command paths. All Python source,
  Python tests, and Python toolchain have been removed from the repository.
- The frontend request path and supported-runtime helpers no longer retain Python-era delegation
  or Python-named context scaffolding inside Haskell modules.
- The `prodbox test` orchestration path runs Haskell test suites via `cabal test` and native CLI
  orchestration.
- All onboarding and AWS administration commands are Haskell-owned in `src/Prodbox/Aws.hs`.
- The legacy tracking ledger is the authoritative cleanup ledger for repository cleanup history.
  It is clear for Phase `6` Python-removal, single-host handoff residue, and the later
  non-Python doctrine-adoption reopen owned by Phases `1`–`4`.
- Root guidance aligns with the post-cleanup Haskell-only repository state.

## Sprint 6.1: Destructive Haskell Rerun from Full Local Delete ✅

**Status**: Done
**Implementation**: `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Prove the clean-room baseline from full local cluster delete and a supported config contract rooted
in the executable-sibling Tier-0 `prodbox.dhall` on the Haskell stack.

### Deliverables

- The authoritative rerun starts from `prodbox cluster delete --yes` and no supported-path generated
  `prodbox-config.json` artifact.
- The local cluster is rebuilt through the Haskell lifecycle path.
- The Pulumi backend is restored and both AWS-backed validation patterns rerun through Haskell
  surfaces.
- The rerun finishes at the supported public-edge and AWS-residue-free state.

### Validation

1. `prodbox cluster delete --yes`
2. Repository artifact proof starts with no supported-path `prodbox-config.json` and no supported
   command recreates it during `prodbox config show` or `prodbox config validate`.
3. `prodbox cluster reconcile`
4. `prodbox config show`
5. `prodbox config validate`
6. `prodbox aws stack eks reconcile`
7. `prodbox test integration aws-eks`
8. `prodbox aws stack test reconcile`
9. `prodbox test integration ha-rke2-aws`
10. `prodbox aws stack eks destroy --yes`
11. `prodbox aws stack test destroy --yes`
12. `prodbox test all`
13. `prodbox edge status`

### Current Validation State

- The destructive operator flow and aggregate runner remain Haskell-only on the runtime surface.
- `src/Prodbox/TestRunner.hs` now resyncs and reuses the canonical operator binary at
  `.build/prodbox` before native aggregate phases begin, so `prodbox test all` remains valid
  even after nested Haskell suites refresh the operator binary.
- Validation steps `2`, `4`, and `5` close on the direct-Dhall config contract: no supported
  command materializes `prodbox-config.json`, and `prodbox config compile` is removed.
- Validation steps `7`, `9`, and `12` remain mapped to the canonical-suite dispatch because the
  named integration payloads in `src/Prodbox/TestPlan.hs` map to executable native Haskell
  validation flows.
- `src/Prodbox/TestPlan.hs` already defines the aggregate end-to-end lifecycle proof surface:
  `prodbox test all` and `prodbox test integration all` run the canonical suite against the
  active substrates (per [substrates.md](substrates.md)) — including `Validation: lifecycle`
  plus supported-runtime bootstrap and postflight — so no separate lifecycle suite is missing
  from the repository.
- `src/Prodbox/TestRunner.hs` encodes the supported-runtime postflight contract: after the
  canonical suite finishes, it re-installs the supported stack on the home substrate, waits
  for `prodbox edge status` to report the required readiness classification, and then
  tears down the AWS substrate's Pulumi stacks.
- Environment-dependent rerun success for this phase remains owned by the named `prodbox`
  commands rather than restated here as a fresh execution log.

### Remaining Work

None.

## Sprint 6.2: Zero-Python Repository Handoff ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the rewrite with no supported-path Python artifacts left in the repository, leaving any
surviving non-Python cleanup explicitly owned by its originating phase in the legacy ledger. The
zero-Python repository handoff is Phase 6's owned surface and is validatable now on the
home/local substrate; the Haskell-only onboarding and AWS administration surfaces are owned by
Phase `7` and tracked there, so Phase 6 closure follows from its own owned-surface validation and
is never gated on Phase `7` completing.

### Deliverables

- The repository handoff no longer depends on Python source files, Python packaging metadata,
  Python test runners, Python type stubs, Python Pulumi programs, or Python-owned onboarding and
  AWS administration helpers.
- The Python-removal portion of the legacy ledger is empty; any surviving non-Python compatibility
  cleanup is owned by its originating phase.
- Root guidance docs and governed doctrine no longer describe Python as the supported runtime.
- The destructive rerun closes after Python removal rather than before it.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test all`
4. Repository artifact-search proof shows that no supported-path Python files or Python toolchain
   ownership artifacts remain.
5. Repository text-search proof shows that no surviving Python-era architecture statements remain
   on the supported path.

### Current Validation State

- The supported implementation surfaces remain Haskell-only. No supported-path Python
  implementation or Python toolchain artifact survives.
- The dead Python-era `DelegateToPython` request constructor and
  `supportedRuntimePythonPath` field are removed from `app/` and `src/`, so the zero-Python
  handoff no longer depends on hidden compatibility scaffolding inside Haskell modules.
- `prodbox dev check` and `prodbox test all` remain the canonical aggregate proof surfaces.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) now preserves completed
  removal history while keeping Python-removal residue at zero. Non-Python doctrine-adoption
  residue owned by reopened Phases `1`–`4` is now closed and is not Phase `6` cleanup.
- The legacy ledger remains clear on Python-removal items.
- Repository artifact and text-search closure remain explicit repo-review gates alongside the
  Haskell command-surface validations, and Sprint `6.1` continues to own the destructive rerun
  contract.

### Remaining Work

None.

## Sprint 6.3: Single-Host Clean-Room Handoff ✅

**Status**: Done
**Implementation**: `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/Settings.hs`, `prodbox.cabal`, `test/unit/Main.hs`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/unit_testing_policy.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Close the destructive rerun and final handoff on the single-host doctrine: one public hostname
`test.resolvefintech.com`, one DNS entry, one certificate, Keycloak-backed Envoy auth and RBAC
for all supported public or admin surfaces, and no `example.com` residue anywhere in the
supported path.

### Deliverables

- The authoritative rerun starts from full local delete and finishes on the shared-host public
  edge rather than the retired multi-host contract.
- The authoritative rerun builds and publishes only the native container architecture of the host
  performing the rerun, with no supported `docker buildx` or cross-arch emulation step.
- At Sprint `6.3` closure, the cleanup ledger returned to zero pending removal after
  `example.com`, dedicated-host public-edge residue, and the final dead supported-runtime helper
  module were removed. Later supported-path residue remained owned by its originating phase rather
  than reopening Phase `6`, and those doctrine-adoption rows are now closed.
- The final handoff proves that any number of supported application or admin services remain
  reachable through one DNS name and one certificate, distinguished only by path and Keycloak-
  backed RBAC.

### Validation

1. `prodbox cluster delete --yes`
2. `prodbox cluster reconcile`
3. `prodbox config show`
4. `prodbox config validate`
5. `prodbox test all`
6. `prodbox edge status`
7. Repository text-search proof that `example.com` is absent from the supported codebase

### Current Validation State

- The supported codebase now closes on the shared-host public edge and native-host-architecture
  custom-image publication. The cleanup ledger remains clear on the Sprint `6.3` single-host
  handoff residue; no current pending rows remain.
- `src/Prodbox/TestRunner.hs` and `src/Prodbox/TestPlan.hs` continue to own the destructive rerun,
  aggregate validation, and postflight restore; `prodbox test all` is the authoritative proof
  surface for validation step `5`.
- The dead `Prodbox.SupportedRuntime` helper module is removed from `src/`, `prodbox.cabal`, and
  `test/unit/Main.hs`, so the final handoff no longer depends on unit-only cleanup helpers
  outside the active command path.
- `src/Prodbox/Host.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/CLI/Rke2.hs`,
  `src/Prodbox/Aws.hs`, `src/Prodbox/Settings.hs`, and `src/Prodbox/Dns.hs` now align to one
  public hostname, one Route 53 record, one shared-edge certificate, and host-native Docker
  publication only.
- The aggregate rerun no longer fails on transient IAM credential propagation or OIDC redirect
  percent-encoding case drift: `src/Prodbox/EffectInterpreter.hs` now retries transient AWS
  validation auth failures, and `src/Prodbox/TestValidation.hs` now matches OIDC redirect headers
  case-insensitively on percent-encoded fragments.
- `src/Prodbox/TestRunner.hs` now treats failed public-edge ACME issuance as bounded
  repository-managed runtime repair during the aggregate rerun: when cert-manager records failed
  issuance attempts for `public-edge-tls`, the native harness deletes the stale
  `CertificateRequest`, `Order`, `Challenge`, and next private-key secret so cert-manager can
  re-issue immediately instead of waiting through the provider backoff window.
- `src/Prodbox/Lib/ChartPlatform.hs` now projects the local Docker image ID into
  `prodbox.io/image-build-id` pod annotations for custom-image chart workloads, so stable-tag
  `api`, `websocket`, and `gateway` releases roll fresh pods whenever the local image build
  changes.
- `src/Prodbox/TestValidation.hs` now retries transient websocket route warm-up timeouts during
  managed validation and decodes websocket plus HTTP JSON payloads through UTF-8-safe helpers so
  non-ASCII claim content does not corrupt the native proof path.
- `src/Prodbox/Workload.hs` now preserves buffered HTTP-upgrade remainder bytes, waits for
  websocket socket readability before frame parsing, and consumes the frame header before mask-key
  parsing so client-sent masked frames reach Redis and broadcast validation without corruption.
- The clean-room closure contract is `prodbox test all`, `prodbox config show`,
  `prodbox config validate`, and `prodbox edge status`, with the aggregate rerun carrying the
  supported-runtime restore through `CLASSIFICATION=ready-for-external-proof` and the named
  `Validation: charts-vscode`, `Validation: charts-api`, `Validation: charts-websocket`, and
  `Validation: lifecycle` surfaces before post-test restore closes on the shared-host edge.
- Supported-path search closure remains intact after the rerun: `example.com` is absent from the
  supported code and governed doctrine surfaces that define the live operator path.
- Repository cleanup history is preserved in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The Phase `6` cleanup
  surface is closed, and the separately owned doctrine-adoption residue in Phases `1`–`4` is now
  closed.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - final Haskell command matrix.
- `documents/engineering/README.md` - engineering index aligned to the final Haskell-only doctrine
  set.
- `documents/engineering/prerequisite_doctrine.md` - clean-room rerun prerequisites on the Haskell
  stack.
- `documents/engineering/storage_lifecycle_doctrine.md` - final lifecycle and retained-root
  contract.
- `documents/engineering/unit_testing_policy.md` - aggregate validation doctrine after Python
  removal.
- `documents/engineering/dependency_management.md` - final non-Python build and dependency posture.

**Product docs to create/update:**

- `README.md` - supported operator flow after the Haskell rewrite.
- `AGENTS.md` - repository guidance for the Haskell architecture.
- `CLAUDE.md` - assistant guidance aligned to the rewritten repository.

**Cross-references to add:**

- Keep the final handoff criteria linked to
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
- Keep the phase-independence framing deferred to the SSoT,
  [development_plan_standards.md](development_plan_standards.md) Standards N (Phase Independence)
  and O (Code-Local vs Live-Infra Proof), rather than restating the doctrine here.

## Sprint 6.4: Clean-Room Authority Migration and Rollback Proof [✅ Done]

**Status**: Done (validated 2026-08-02). The versioned exact-prefix migration/restore/cleanup
composition, post-cutover rollback refusal, installed-binary dry-run, and production legacy-residue
scan are complete.
**Deployment qualification**: pending
**Implementation**: `Prodbox.Test.CleanRoomHandoff` owns the 18-boundary versioned action trace,
exact-prefix resume/refusal fold, rollback disposition, retired path/fragment registry, and stable
plan renderer. `clean-room-handoff` is a named canonical validation that scans production sources
and renders the same plan through the built executable; unit fixtures cover every interruption
prefix and negative residue/rollback cases.
**Live-proof**: pending after code-local preparation; the current-revision home clean-room run is a
deployment-qualification axis rather than phase-status evidence
**Independent Validation**: focused Sprint-`6.4` 8/8, installed-binary
`test integration clean-room-handoff` exit 0, full unit `3028/3028`, generated CLI registries/docs,
and `prodbox dev check` exit 0 on 2026-08-02. The destructive home aggregates remain separate
deployment-qualification evidence under Standards O/P.
**Docs updated**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/unit_testing_policy.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
and `README.md`

### Objective

Prove that an empty-checkout home deployment can migrate retained state exactly once, survive
interruption, restore the complete supported platform, and contain no surviving legacy lifecycle
transport before handoff.

### Deliverables

- Add a clean-room scenario that starts from supported legacy retained fixtures, performs the
  authority-epoch cutover, interrupts at every migration boundary, and resumes to one converged
  writer.
- Prove a post-cutover rollback refuses before mutation and an interrupted pre-cutover run can
  safely retry the old observation phase without dual-write.
- Exercise cluster delete/reconcile, Vault sealed/unsealed transitions, broker handoff, Lifecycle
  Authority journal replay, gateway restoration, target-agent restoration, charts, and always-run
  cleanup through the installed binary.
- Add zero-residue guards for gateway authority/bootstrap/target routes, host-direct object store,
  obsolete ServiceAccounts/RBAC, duplicated endpoints, and stale config fields.
- Run `LCPC-2026-07-11` plus two consecutive home aggregates under the exact rendered envelopes;
  populate the exact typed qualification artifact defined by Sprint `5.19` rather than a local
  subset, including separate complete superseded/replacement secret-safe source/config/image/
  topology-wiring/envelope/load identities, each source-manifest exclusion-policy identifier/
  version/digest, commands, counterexample results, full fault matrix, aggregate outcomes, cleanup/
  residue, timestamps, and evidence digest. Secret-dependent inputs use only opaque Authority
  receipt/generation IDs or Vault-keyed HMAC commitments; no public evidence hashes plaintext
  secrets. This is prerequisite evidence; Sprint `8.12` reruns and owns final both-substrate
  qualification after the shared SES changes.

### Validation

1. All migration interruption fixtures converge or fail closed with one authoritative remedy.
2. Dry-run plans expose migration/cutover/cleanup order without mutation.
3. Installed-binary fake traces cover success, failure, cancellation, and restart.
4. Repository and rendered-chart scans prove zero legacy transport/config/RBAC residue.
5. Qualification fixtures reject excluded secret/runtime/build-root manifest members, missing or
   drifted source-manifest policy identities, and public raw hashes of secret-dependent inputs.
6. `prodbox config generate`, `config validate`, local suites, docs checks, and `prodbox dev check`
   pass.

### Closure Evidence

- Every durable prefix resumes at the exact next boundary; skipped, reordered, and duplicated
  boundaries refuse.
- Pre-cutover interruption permits only legacy observation retry; activation changes rollback to a
  pre-mutation refusal and the plan proceeds forward through restore and cleanup.
- The installed command scans `app/`, `src/`, and `charts/` for retired transport paths/fragments and
  emits the governed dry-run plan.
- The real home clean-room run remains deployment qualification; Sprint `7.33` owns AWS parity.

## Sprint 6.5: Typed Teardown Single-Writer Cutover and Clean-Room Handoff [🔄 Active]

**Status**: Active. Sprint `4.91` closed the checkpoint-custody registry-key/Pulumi-stack-ID
mismatch exposed by this sprint's live cascade recovery. The former gates are complete: Sprint
`5.36` landed the lifecycle-kernel `TestRunner` client, Sprint `7.38` sealed the run's DNS hosted
zone into the compiled observation scope, Sprint `4.89` landed the custodial-capability disposition,
and Sprint `4.86` landed the non-public candidate entrypoint that drives the total dispatcher over
a durable descriptor-bound run. Sprints `7.39` and `7.40` closed the last of them on 2026-09-11: the
ephemeral Kubernetes client's credential mechanism, which this sprint's own live campaign proved had
never authenticated. Deploy the corrected runtime, recover the registered AWS graph, then resume
activation qualification. This is the plan suite's only open row.
**Deployment qualification**: pending — clean-room/destructive evidence from the superseded
cascade is invalid for the replacement composition.
**Doctrine**: [Lifecycle Control-Plane Architecture § 12, “Cutover and
Rollback”](../documents/engineering/lifecycle_control_plane_architecture.md#12-cutover-and-rollback),
[Lifecycle Reconciliation Doctrine § 5b, “Canonical recover-to-clean
cascade”](../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade),
[Pure FP Standards § 7, “GADT-Indexed State
Machines”](../documents/engineering/pure_fp_standards.md#7-gadt-indexed-state-machines), and
[Integration Fixture Doctrine § 7, “Clean-Room Migration
Fixtures”](../documents/engineering/integration_fixture_doctrine.md#7-clean-room-migration-fixtures).
**Implementation**: `src/Prodbox/Test/CleanRoomHandoff.hs`,
`src/Prodbox/TestValidation.hs`, `src/Prodbox/CLI/Rke2.hs`,
`src/Prodbox/Test/Qualification/SourceIdentity.hs`,
`src/Prodbox/Test/Qualification/Evidence.hs`,
`src/Prodbox/Capacity/ProviderWorkerBudget.hs`, `docker/prodbox.Dockerfile`, the four
`pulumi/*/Pulumi.yaml` projects, and the registered retired-symbol scanner.
**Closure dependency**: none. It was Sprint `7.40`, which completed the ephemeral Kubernetes
client's consolidation onto the credential mechanism Sprint `7.39` established; both landed
2026-09-11 and the dependency is discharged.
**Backward dependency**: Sprint `7.40`, discharged 2026-09-11 and retained here because
[Standard N.2](development_plan_standards.md#n-phase-independence-and-execution-order) requires the
admission to stay legible where the deviation happened. Activating the replacement as the sole
public writer while its AWS drain could not authenticate would have stranded every EKS teardown path
behind a writer with no rollback: the legacy route this sprint deletes is the only one an operator
could fall back to, and Sprint `6.5` proved on 2026-09-11 that the replacement's ephemeral
Kubernetes client had never authenticated on any live run.
**Live-proof**: pending and non-blocking for code-local closure. Two consecutive destructive home
cycles run the qualification-only replacement candidate under its exact identity before any public
activation. Standard P forbids activation and legacy deletion until the current-revision home row is
`proven`; the post-activation identity must then be qualified before the ledger row can complete.
**Independent Validation**: pure prefix/resume and rollback folds, installed-binary fake traces,
repository/rendered-resource scans, unit/integration suites, and `prodbox dev check`.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/streaming_doctrine.md`,
`documents/engineering/pure_fp_standards.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/unit_testing_policy.md`, `documents/engineering/dependency_management.md`,
root `README.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/system-components.md`, and
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Build and locally validate the qualification-gated cutover from the handwritten generic/home
cascade to the typed recover-to-clean graph, with one writer, one durable cleanup namespace, and
type-indexed rollback legality. Before qualification, the legacy route remains the sole public
writer and the replacement is callable only by the qualification-only runner. After Standard-P
evidence authorizes activation, consume that evidence to make the replacement the sole public writer
and remove the legacy generic/home path. Sprint `7.36` supplies the exact AWS adapter and Sprint
`7.38` the complete DNS scope; this sprint makes no live AWS parity claim.

### Deliverables

- Bind the clean-room handoff artifact to stable counterexample `TEARDOWN-2026-08-15` and record for
  both superseded and replacement identities: complete `SourceIdentity` (Git HEAD, clean/dirty,
  source-manifest policy ID/version/digest and manifest digest), secret-safe generated-config,
  component-image, topology/wiring, resource-envelope, authored-load, interpreter, persistence, and
  cleanup-schema digests. Also record substrate, exact commands, timestamps, evidence digest,
  complete fault and cleanup results, the constant causal profile and exact old→new envelope
  mapping, and the separate production profile required by Standard P.
- Permit a pre-activation shadow reader to compare old discovery against exact replacement
  observations. Never permit two cleanup writers or two operation-ID allocators.
- Define a private `CutoverState (phase :: CutoverPhase)` GADT. Only
  `CutoverState 'PreActivation` contains `LegacyWriterPermit` and is accepted by
  `rollbackLegacy`; `activateReplacement` additionally requires opaque current-revision
  `QualificationPassed` evidence for the exact replacement identity, consumes that state/permit,
  and returns `CutoverState 'PostActivation` containing the sole `ReplacementWriterPermit`. There
  is no post-activation legacy-rollback constructor or function, so activation without qualification,
  dual writers, and runtime-only rollback refusal are unrepresentable.
- Render one staged cutover plan: qualification-only candidate execution; qualification receipt
  observation; single-writer activation; legacy route/identity deletion; and post-activation
  requalification. The activation and deletion stages cannot enter Apply without the matching
  `QualificationPassed` witness. Deletion changes the identity and therefore returns qualification
  to pending until the post-activation campaign passes.
- Extend the exact-prefix interruption model through recovery-profile start, observation,
  drain/backstop, provider cleanup, absence read-back, escape audit, report receipt, and final local
  uninstall/read-back completion receipt. Incomplete results carry `RecoveryPlaneDisposition` as
  `Established`, `NotEstablished`, or `Lost` and claim a preserved live plane only for
  `Established`.
- **Received from Sprint `4.84` on its closure (2026-08-17).** Convert the bespoke
  `runNativeDeleteCascade` onto the exact-keyed selection Sprint `4.84` landed: it still reaches its
  targets through the surface- and run-keyed creation slot and visible residue, and must reach them
  through `selectRegisteredStackGenerationForCleanup` instead. This lands with the single-writer
  activation rather than in front of it, because converting the legacy caller first would build the
  new selection on top of the very route this sprint deletes.
- Extend installed-binary and repository/chart scans for every legacy symbol, callback, Gateway-owned
  caller identity, no-RKE2 cascade shortcut, and uninstall-on-incomplete generic/home route
  registered in the deletion ledger. Before activation the scanner requires the exact bounded
  legacy set and rejects any new site; after qualified deletion it requires zero. Do not scan for or
  remove the checkpoint-derived EKS kubeconfig/adapters here; that explicit AWS residual remains
  registered to Sprint `7.36`.
- Through the qualification-only runner, run two consecutive home destructive cycles without
  changing the public writer: stopped/absent API recovery, exact convergence,
  pre-uninstall report backup/read-back, one-shot permit, uninstall-last, exact host absence,
  local-completion receipt, rebuild, and repeated cascade. Record the exact intended-retained set
  and zero unexpected residue under one run/revision/account/region/substrate/report-digest scope.
  After qualified activation and legacy deletion, rerun the required Standard-P campaign for the
  resulting source/deployment identity before claiming the ledger row complete.
- **Received from Sprint `4.86` on 2026-08-20 under
  [Standard N](../DEVELOPMENT_PLAN/development_plan_standards.md#n-phase-independence-and-execution-order):
  the installed cascade's fake traces and terminal narration.** The candidate entrypoint Sprint
  `4.86` landed is package-private and drives no public command, so the traces its own validation
  item asked for had no installed surface to run against. They land with the single-writer
  activation, over the command this sprint exposes.
- **Received from Sprint `4.85` on 2026-08-18 under
  [Standard N](../DEVELOPMENT_PLAN/development_plan_standards.md#n-phase-independence-and-execution-order):
  total-decommission program-tag convergence.** Sprint `4.85` owns and has landed the *measurement* —
  `Prodbox.Lifecycle.Decommission.ProgramTag` names the closed semantic operation universe, both
  classifiers are total, and `validateDecommissionProgramTagParity` checks the authored claim against
  both measured images in `prodbox dev check`. What it cannot own is convergence: making every tag
  two-sided requires the compiled desired-absence program and the signed `DecommissionNode` manifest
  to become one universe, which is exactly the single-writer cutover this sprint performs over the
  adapters Sprint `7.36` supplies — **this sprint's declared `**Backward dependency**`, recorded once
  in the field above**. Held in Phase 4 it was a Phase-4 validation item that only a Phase-6/7
  composition could satisfy; it belongs here.

### Validation

1. Every interruption prefix resumes the exact next replacement action with the same stable IDs;
   reordered, skipped, or duplicated transitions refuse.
2. Shadow observation may coexist before activation; mutation ownership is singular at every state.
3. Compile/type tests can construct pre-activation rollback and qualified activation, but cannot
   construct activation without `QualificationPassed`, post-activation legacy rollback, a
   dual-writer state, or a replacement writer without consuming the legacy permit.
4. Before qualification, the installed public command exposes only the legacy generic/home writer
   while the qualification-only command reaches the exact replacement plan without a public writer
   permit. After activation, the installed public command exposes only the replacement plan. The
   AWS adapter slot deterministically fails closed without pretending later Sprint `7.36` work is complete.
5. The frozen counterexample fails its superseded expectations and the replacement satisfies the
   exact-keyed reference oracle while preserving its expected `CascadeIncomplete`
   caller-observation failure; test pass is not narrated as cascade success.
6. No uninstall plan is constructible without private `ReadyToUninstallEvidence` from exact clean
   observations, the exact intended-retained audit set, backed-up pre-uninstall report, and one-shot
   permit. `CascadeCompleteEvidence` additionally requires exact `LocalUninstallEvidence` and the
   matching read-back `LocalCompletionReceipt`, all under the same scope/digest.
7. Local fake qualification receipts and mutation tests prove the staged plan cannot reorder
   qualification, activation, deletion, and post-activation requalification. The pre-activation
   scanner accepts only the exact registered legacy set; its post-activation mode accepts none.
8. After single-writer activation, `decommissionProgramTagImplementation` measures
   `CompiledProgramAndRunner` for **every** `DecommissionProgramTag`, with the count asserted so a
   later one-sided tag fails the build. Before activation the same assertion is the measured
   partial state Sprint `4.85` closed on, so this item distinguishes convergence achieved from
   convergence assumed.
9. The EKS drain's Kubernetes UID observation authenticates and returns, rather than exhausting its
   wall clock. Sprints `7.39` and `7.40` landed the credential mechanism and removed the third
   statement of it on 2026-09-11, so a candidate cycle can now reach the drain; this item is
   unsatisfied until a live cycle shows it returning.
10. Two consecutive home clean-room candidate cycles produce the complete artifacts, uninstall last,
   and leave only intended retained resources. These live results remain non-blocking Standard-P
   evidence and do not themselves make code-local closure contingent on infrastructure.
11. **Received from Sprint `4.86` on 2026-08-20 under
    [Standard N](development_plan_standards.md#n-phase-independence-and-execution-order).**
    Installed-binary fake traces of the activated public cascade cover success, failure,
    cancellation, response loss, restart, and terminal narration, each carrying the exact resource
    keys, observation authorities, and `CleanupRunId`. Sprint `4.86` cannot own this: it
    deliberately activates no public writer, so no installed command's narration exists to trace.
    Held there it was a Phase-4 validation criterion that only this sprint's composition could
    satisfy.

### Current Validation State

- The code-local clean-room validation passes after registering the qualification evidence schema's
  intentional superseded-executor label in the exact pre-activation legacy inventory. Canonical
  `prodbox dev check` passes on that revision.
- Live candidate cycle `pre-1` on 2026-08-31 built runtime image `sha256:5789285c...`, published
  registry manifest `sha256:43583754...`, and imported the exact image into RKE2. It stopped before
  AWS harness setup and before candidate execution: Authority Backup's Recreate rollout was applied
  without Helm waiting, backup admission immediately opened its transport, and the client timed out
  before the requested Deployment revision became Ready. The replacement Pod became Ready directly
  after the refusal. Stable counterexample
  `AUTHORITY-BACKUP-ROLLOUT-USE-BEFORE-READY-2026-08-31` requires an exact
  requested-revision-plus-availability barrier between chart apply and admission. No qualification
  artifact or activation witness was produced.
- That counterexample is closed code-locally. `observe_authority_backup_rollout_ready` is now a
  graph-owned component-readiness step after the no-wait chart mutation and before admission. Its
  production target requires both `DeploymentRevisionObserved` and `DeploymentAvailable`, and it
  uses the existing 60-attempt deployment-revision observation budget. Both affected golden plans,
  focused graph/readiness tests, installed `clean-room-handoff`, all **4759/4759** primary unit tests,
  and canonical `prodbox dev check` pass. Live cycle `pre-1` remains the next validation and no
  qualification artifact or activation witness exists yet.
- That live retry builds local image
  `sha256:4ada2f7e2ad6b4231b66ca567a05a0675b59717540a300820ff47e88e4fc7b27` in 1008.4 seconds,
  publishes registry manifest
  `sha256:e9d2f6465b022dff86acba9ba359a67c5f2cbac55637408d2ddcf25234cd4966`, and imports OCI
  manifest `sha256:b913c4ad81bdcdc11d1f42dd0f3eb71eb9eb1d0a1e25a178f6bfeba3c2976a99` in 99.8 seconds.
  The retained Lifecycle-provider credential reads back current at Generation 2, and managed ACME
  EAB ingress reaches the new committed-effect recovery but fails closed at
  `ExternalMaterialIngressClientUnavailable "retained-receipt-recovery/target-source-unavailable"`.
  Candidate execution is not reached, operational credentials are preserved, and no qualification
  artifact or activation witness exists. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-SOURCE-UNAVAILABLE-2026-09-01` owns this exact authenticated Target
  source-observation refusal. Diagnose the retained target/schema/operation/generation coordinates
  and custody observation result before changing recovery semantics; the legacy public writer
  remains sole.
- Read-only Pod/log inspection proves the new Target Agent and Lifecycle Authority are both Ready
  with zero restarts, but the Authority currently collapses every Target transport, codec, status,
  refusal, unavailable, and unexpected-response result to the same `target-source-unavailable`
  token without a diagnostic. The exact retained-custody branch therefore cannot yet be
  distinguished. Before altering recovery behavior, add a closed payload-free diagnostic
  classifier at this composition boundary and rerun the supported cycle; it may expose only the
  error constructor/cause class, never returned detail or custody values.
- The behavior-neutral classifier is now landed. It exhausts transport, codec, status, known
  refusal/unavailable, unexpected, and unknown-detail branches; private response text collapses to
  `refused-other` or `unavailable-other`, and only the closed token is logged. The focused lifecycle
  group passes **19/19**, the full primary suite passes **4770/4770** in 86.69 seconds, and canonical
  `prodbox dev check` passes with HLint `No hints` and warning-clean all-target compilation. The
  synchronized executable is exact at
  `sha256:439e7351281a0e307f77d185eb36ae2040cf3af019f288020c8529b7f89104ef`; rerun live `pre-1`
  on this documentation-inclusive diagnostic revision before changing recovery behavior.
- That diagnostic retry builds local image
  `sha256:720c563bb2374e944f9ae7bc44671bd4896bc112b626aee6294c9ecdacab8749` in 1064.2 seconds,
  publishes registry manifest
  `sha256:c85c2663da5fdb2513bc09f97211a4db4c5ceb1a4d6a54d0aefa90f69de636a5`, and imports OCI
  manifest `sha256:e7f1a6d2a0f2ef87c8c747673f826d3c98e401b6ec61009c26809836a94a6bfe` in 96.5 seconds.
  The protected Authority log classifies the authenticated Target response exactly as
  `source-absent`: retained ACME EAB custody has neither data nor metadata. The earlier attach
  decode failure therefore did not prove the worker effect, and the committed-permit ambiguity is
  now resolved by the effect boundary's authoritative positive absence. Candidate execution
  remains unreached, credentials remain preserved, and no artifact or witness exists. Close
  `AWS-HARNESS-ACME-EAB-RETAINED-SOURCE-UNAVAILABLE-2026-09-01` with an exact
  permit-committed/expired/positive-source-absence recovery transition that preserves the immutable
  request binding and obtains a fresh bounded authorization before any successor Job; present,
  mismatched, corrupt, or unobservable custody must never authorize a retry.
- The exact absence-authorized recovery is now landed. Positive absence is a distinct typed Target
  response, not a refusal string. Lifecycle Authority may consume it only while the old signed
  permit and retained intent are expired, the replacement deadline is active and strictly later,
  and the operator request plus permit ID are byte-for-byte unchanged; it CAS-read-backs a reset to
  the fresh `IntentCommitted` state. The workflow must still prove the exact old Job stably absent
  before it creates the successor, whose new attestation receives a fresh signed permit. A recovered
  source instead commits/returns the old receipt, while target mismatch, corruption,
  unobservability, active permit, deadline drift, and binding drift remain closed. The focused
  lifecycle group passes **20/20**, the full primary suite passes **4771/4771** in 86.18 seconds,
  and canonical `prodbox dev check` passes with HLint `No hints` and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:32a629772f44b35be763c1270de5e83deaccc153885f4da92adc1c9e0ead8612`; rerun live `pre-1`
  on this documentation-inclusive revision.
- That retry builds local image
  `sha256:8c8f786b6c81ad4ab0b45e3b010d665ffc1c18e28de52e7c34a25c42a316774c`, publishes registry
  manifest `sha256:1d99d8b7fac629ece765f3060fb990b32c2c8acda0c4f9a9b10b044651afd522`, and imports OCI
  manifest `sha256:b4631f49ef5b5bb3bff710384f60d384773b093634ee357e0378a6a2c8182146`. The retained
  Lifecycle-provider credential reads back current at Generation 2 and the exact positive-absence
  recovery reaches its fresh successor worker, but managed ACME EAB ingress fails at
  `ExternalMaterialWorkflowJobFailed (CredentialProvisionerJobReceiptInvalid
  "ExternalMaterialTargetReceiptDecodeFailed")`. Candidate execution is not reached, operational
  credentials are preserved, and no qualification artifact or activation witness exists. Stable
  counterexample `AWS-HARNESS-ACME-EAB-ABSENCE-RETRY-RECEIPT-DECODE-FAILED-2026-09-01` owns this
  exact successor-worker receipt boundary. Preserve the retained operation and diagnose the exact
  Job/Pod disposition plus binary attach stdout before changing the codec or recovery transition;
  the legacy public writer remains sole.
- Read-only postflight proves the exact successor Job and Pod absent. Events prove the Pod pulled
  the bound registry digest, started, ran for 13 seconds, and was UID-cleaned. The repeated decode
  failure with `--quiet` falsifies the earlier assumption that banner suppression makes raw CBOR a
  stable Kubernetes record. The repository's already live-proven AWS-admin worker boundary
  establishes the actual source-specific grammar: attach carries one leading LF record separator
  and Pod logs carry one terminal LF, so an unchanged canonical binary receipt needs a
  fixed-version canonical-base64 ASCII envelope. Close this counterexample with a distinct
  external-material envelope prefix; accept attach only as exactly separator plus envelope, admit
  the Pod-log recovery only for an exact empty attach and exactly one whole canonical envelope line
  with the required terminal LF, and keep the decoded inner receipt subject to the unchanged
  canonical binary decoder. Generic trimming, substring selection, cross-schema envelopes,
  non-empty-attach fallback, and weakened receipt validation remain forbidden.
- The source-specific carrier correction is now landed. The worker writes one LF plus
  `prodbox-external-material-target-receipt-v1:<canonical-base64>`; attach accepts only that
  complete record, and only an exact empty attach admits the same attested Pod/container's log with
  one final LF and exactly one canonical whole envelope line. The inner receipt still passes the
  unchanged canonical binary decoder and exact intent binding. Focused external-material lifecycle
  tests pass **22/22**, including raw/missing-separator/trailing-LF/CRLF/ambiguous-envelope
  rejection and non-empty-attach fallback suppression. The full primary suite passes **4773/4773**
  in 85.43 seconds. Canonical `prodbox dev check` passes with pinned formatting, HLint `No hints`,
  and warning-clean all-target compilation. The synchronized executable is exact at
  `sha256:b93b857931b945b126dca309fe8b7bfc0f2801c9fbd7e138de9a4bbe6cb50955`; rerun live `pre-1`
  on this documentation-inclusive revision. The legacy public writer remains sole.
- That retry builds local image
  `sha256:545f7a4a05159166a92e69a0539e594cd699faccbf3693672eb6512b33276933` in 1017.4 seconds,
  publishes registry manifest
  `sha256:cb0d01d122f659eead7f4f6a79cd94d74fad47d95efdfb9461a9c586c70ab18b`, and imports OCI
  manifest `sha256:c41f5f9668a07700798e8549e57fe9454528a6f9c2c6403553d8a247be42d01a` in 91.6 seconds.
  The retained Lifecycle-provider credential reads back current at Generation 2, but managed ACME
  EAB ingress fails at `ExternalMaterialWorkflowJobFailed (CredentialProvisionerJobReceiptInvalid
  "ExternalMaterialTargetReceiptEnvelopeInvalid")`. Candidate execution is not reached,
  operational credentials are preserved, and no qualification artifact or activation witness
  exists. Stable counterexample `AWS-HARNESS-ACME-EAB-TEXT-ENVELOPE-INVALID-2026-09-01` owns this
  exact source-specific carrier-shape refusal. Read-only postflight proves the exact Job and Pod
  absent after a 13-second run of the bound registry manifest, while the Authority's retained
  receipt recovery reports `target-source=source-absent`. Static inspection also proves the worker
  revokes its session exactly once; the duplicate revocation suspected from interleaved inspection
  output does not exist. The remaining carrier error therefore collapses an exact worker terminal
  refusal from the merged Pod-log stream into an envelope error. Before changing effect semantics,
  add one closed, value-free worker terminal-cause vocabulary and classify only a unique exact
  whole terminal line from attach stderr or the Pod-log recovery. Unknown, absent, or ambiguous
  terminal lines remain transport/receipt refusals; raw stderr, stdin, Vault bodies, tokens,
  provider output, counts, and wire values remain excluded. The legacy public writer remains sole.
- That value-free classifier is now landed without changing the worker effect program. The worker
  exhaustively collapses its internal error constructors to fourteen unique fixed terminal tokens;
  attach and Pod-log recovery recognize only one exact whole prefixed line. Unknown, absent, or
  multiple prefixed lines retain the existing generic transport/receipt refusal, and attach no
  longer retains raw stderr. Focused external-material lifecycle tests pass **23/23**; the full
  primary suite passes **4774/4774** in 86.83 seconds. Canonical `prodbox dev check` passes with
  generated-artifact/documentation policy, pinned formatting, HLint `No hints`, and warning-clean
  all-target compilation. The synchronized executable is exact at
  `sha256:a320aa1985df95d9b381ee2ef19d6de24f510185759d5d41b27f2a42feb2473f`.
  Rerun live `pre-1` on this documentation-inclusive revision to obtain the exact worker refusal;
  no preactivation cycle has passed and the legacy public writer remains sole.
- That retry builds local image
  `sha256:65a4c384b28099cc16f85d03b0303e94b7e55d87fe87e3c64661b82cdc291000` in 1052.0 seconds,
  publishes registry manifest
  `sha256:cc9b87f1e714065172d9c8ab29c72fe221bdd7bf81a7bc77c5774794a5a9f81d`, and imports OCI
  manifest `sha256:c3dcebca427107997f16f1bbe0a25160f35834476fdf606d085f69bf2ebee375`
  in 88.0 seconds. The exact successor Pod pulls that new registry manifest, runs for 13 seconds,
  and is UID-cleaned with its Job; both are absent. Authority recovery again reports
  `target-source=source-absent`, while the public result remains
  `ExternalMaterialTargetReceiptEnvelopeInvalid`. Thus the classifier observed no unique exact
  known terminal line; stable counterexample
  `AWS-HARNESS-ACME-EAB-TEXT-ENVELOPE-INVALID-2026-09-01` remains open. Before changing worker or
  custody semantics, add a behavior-neutral closed observation over attach stdout/stderr and
  Pod-log stdout/stderr that records only process-exit, empty/nonempty capture, and terminal-line
  none/known/unrecognized/ambiguous disposition. Raw bytes, text, values, and counts remain
  forbidden. No qualification artifact or activation witness exists; the legacy public writer
  remains sole.
- The behavior-neutral capture observation is now landed. Failed attach and only the final failed
  Pod-log recovery emit the closed source/process/stdout/stderr topology; exact tests prove an
  injected captured marker and numeric exit code cannot render. Focused external-material lifecycle
  tests pass **24/24** and the full primary suite passes **4775/4775** in 87.33 seconds. Canonical
  `prodbox dev check` passes with pinned formatting, HLint `No hints`, and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:e886e1c525a2b7386e1bfddc55fd23ce97ba8de22a741bda2e863321f27f5f03`.
  Rerun live `pre-1` on this documentation-inclusive revision; no preactivation cycle has passed
  and the legacy public writer remains sole.
- That retry builds local image
  `sha256:86372e4aa2d4ac39264966f99b330bbe45f04bc02299be5ccebd57838c62009c` in 1003.7 seconds,
  publishes registry manifest
  `sha256:cfcb06752ad8231c79f2fc1a55b051dba939810a162210acf9a27e154892964b`, and imports OCI
  manifest `sha256:28a65168a8f5b53c2afb77898152c3e98021a7a4ee999bfdd148f86c3f7bf526`
  in 96.2 seconds. Both closed observations are exact:
  `source=attach/process=success/stdout=empty/stdout-terminal=none/stderr=empty/stderr-terminal=none`
  and the identical empty/no-terminal shape from `source=pod-log`. Events prove the exact Pod pulls
  the new manifest, remains alive for 13 seconds, and is killed only by exact UID cleanup; its Job
  and Pod are absent, and Authority source recovery remains positively absent. This rules out a
  worker refusal and live-proves that the worker is blocked waiting for stdin EOF. The native
  external-material Job has `stdin: true` but omits `stdinOnce: true`, unlike the already working
  AWS-admin renderer and chart reference, so detach leaves the container stream open. Close stable
  counterexample `AWS-HARNESS-ACME-EAB-TEXT-ENVELOPE-INVALID-2026-09-01` by adding the missing
  `stdinOnce: true` lifecycle binding and pinning it in the native manifest regression; retain the
  now-proven value-free observation. No qualification artifact or activation witness exists; the
  legacy public writer remains sole.
- The native Job now binds `stdinOnce: true` and the manifest regression requires it. Focused
  external-material lifecycle tests pass **24/24**; the full primary suite passes **4775/4775** in
  86.38 seconds. Canonical `prodbox dev check` passes with pinned formatting, HLint `No hints`, and
  warning-clean all-target compilation. The synchronized executable is exact at
  `sha256:55b2d252f29ec44e03cf2853f1e4a3bfacc70e8786cbca043d5ec79795fab9d0`.
  Rerun live `pre-1` on this documentation-inclusive revision. No preactivation cycle has passed
  and the legacy public writer remains sole.
- That corrected retry builds local image
  `sha256:3e4e9a9adc2004a7cd621c78abcdd4efc5c2b97d37b4a2c2644e78827dcad01f`, publishes
  registry manifest
  `sha256:d18ca466b85e9bdd138500155793b629b16796dab92b8c965156d131dde12164`, and imports OCI
  manifest `sha256:64ad7f49995bf6b7866881488a7b0db7442c09c8353072774fc90123f0a184bc` in 105.5
  seconds. The external-material worker now receives EOF, seals the retained source, returns its
  canonical receipt, and is UID-cleaned with its Job; both one-shot kinds are absent. The workflow
  then crosses Authority receipt commit and reaches retained Target delivery, where the Target
  Agent refuses exact `retained source binding mismatch`. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-SOURCE-RECEIPT-BINDING-MISMATCH-2026-09-01` owns this new
  boundary. The receipt currently carries the retained commitment, ciphertext digest, generation,
  and Vault version but omits the retained custody HMAC receipt ref; the host delivery projection
  consequently invents the permit id as that source receipt, which cannot equal the Target Agent's
  observed source. Close only that lossy projection by carrying and validating the exact custody
  source receipt in the canonical external-material receipt and using it for delivery/recovery.
  Candidate execution is not reached, exact terminal cleanup is not proved, operational
  credentials are preserved, no qualification artifact or activation witness exists, and the
  legacy public writer remains sole.
- The counterexample is now closed code-locally. The external-material canonical receipt includes
  the validated exact custody HMAC source receipt, its carrier advances to the distinct
  `prodbox-external-material-target-receipt-v2:` prefix, worker and retained-source recovery both
  populate the binding, and delivery consumes it without substitution. The retained state advances
  to version 3; a canonical completed v2 state is validated and migrates only to its signed
  permit-committed phase so the existing authoritative Target-source recovery must reconstruct and
  CAS-commit the complete receipt before delivery. The focused external-material group passes
  **25/25**, including the v2 migration, invalid-source-receipt refusal, and exact delivery
  projection; the full primary suite passes **4776/4776** in 86.26 seconds. Canonical `prodbox dev
  check` passes with pinned formatting, HLint `No hints`, generated/documentation policy, and
  warning-clean all-target compilation. The synchronized executable is exact at
  `sha256:aaea893f7e2e2ed6e695a76e2fddfed9ee0d113e1c474d0b2f8f57a0b585bb00`.
  Rerun documentation-inclusive canonical validation, then live `pre-1`; no preactivation cycle
  has passed, no artifact or witness exists, and the legacy public writer remains sole.
- That live retry builds local image
  `sha256:7e345ff3299eeb44b527f58db2aa60d91dd1b37a21e0ece0bcd531f8255ab55e` in 1008.4
  seconds, publishes registry manifest
  `sha256:b2875957738413e28551b8a8f61850ef9e3a9bc3d2bca279e7332a91cd2effbe`, and imports OCI
  manifest `sha256:fdcd7b342994c39b52fa2f03105ca6534e9c68d172ed0b1a5ad439e25a6a83cc` in 110.5
  seconds. It live-proves the state-v2 migration and exact custody-source-receipt correction by
  crossing the former `retained source binding mismatch`. The next refusal is exact
  `retained delivery expired without an observed Target receipt; use a successor operation`: the
  previous failed attempt left the Authority-owned delivery outbox pending past its absolute
  deadline before Target materialization, but the host reconstructs the same fixed
  `delivery-<ingress-operation>` identity on every replay. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-DELIVERY-EXPIRED-OPERATION-REUSE-2026-09-01` owns this
  successor boundary. Close it inside the retained delivery coordinator: after durably expiring an
  unobserved pending intent, derive and persist one deterministic successor operation from that
  predecessor rather than asking the caller to invent or select an identity; exact replay must
  resume the same successor and may not rerun the expired effect. Both Credential Provisioner Job
  and Pod kinds are absent after the attempt. Candidate execution is not reached, exact terminal
  cleanup is not proved, operational credentials are preserved, no qualification artifact or
  activation witness exists, and the legacy public writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-RETAINED-DELIVERY-EXPIRED-OPERATION-REUSE-2026-09-01` is now complete.
  `ReplaceExpiredRetainedMaterialDelivery` atomically swaps only a strictly expired pending
  predecessor for the Authority-derived SHA-256 successor operation; source receipt, target,
  generation, and attestation remain exact, while the ephemeral key must differ and the successor
  deadline must be fresh and later. Initial and successor attempts receive an Authority-time
  five-minute deadline rather than reusing the ingress deadline. The coordinator recognizes only
  the base operation plus 256 deterministic successors with the exact logical binding, and an
  applied-without-response replacement replays as `RetainedDeliveryAlreadyReplaced` before
  executing with the same in-memory key. The focused retained-material group passes **14/14**; the
  full primary suite passes **4779/4779** in 87.24 seconds. Canonical `prodbox dev check` passes
  with pinned formatting, HLint `No hints`, generated/documentation policy, and warning-clean
  all-target compilation. The synchronized executable is exact at
  `sha256:de4010d6a06adff4cae7b5f3e8ea2647126df9e7cf7b8cc922df6782b771930b`.
  Rerun documentation-inclusive canonical validation, then live `pre-1`; the counterexample is not
  live-closed by local evidence. No preactivation cycle has passed, no artifact or witness exists,
  and the legacy public writer remains sole.
- The documentation-inclusive canonical gate passes, then the live retry builds local image
  `sha256:5fff1a65b39268b913b72fa46c18cef045a46d732e9ae097cdc5b2aa39198efd` in 1002.0
  seconds, publishes registry manifest
  `sha256:4602c8fda12fe168083a174ab4e658c6687f5656adbef058b05330388580a967`, and imports OCI
  manifest `sha256:67c6d74cbd91072e403d2312893e4c5d1e801dfaa4e2d0e62b46f3296946614b` in 108.6
  seconds. Home reconcile and retained credential generation complete, but ACME EAB delivery
  refuses before successor recovery at `RetainedSealDeadlineExpired`. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-SOURCE-SEAL-DEADLINE-REUSE-2026-09-01` owns this boundary:
  `ensureRetainedMaterialCurrentSource` reconstructs its metadata-only catalog seal using the
  expired external-ingress request deadline for both admission and predecessor grace.
  Source-catalog reconciliation is a fresh Authority transaction and must receive its own bounded
  Authority-time deadline; replaying an old ingress request must not mint time for the ingress
  effect or cause an already receipt-backed source to be refused solely because that request
  expired. The candidate did not reach successor execution, so the preceding counterexample is not
  yet live-closed. Exact terminal cleanup is not proved, operational credentials are preserved, no
  qualification artifact or activation witness exists, and the legacy public writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-RETAINED-SOURCE-SEAL-DEADLINE-REUSE-2026-09-01` is complete.
  `ensureRetainedMaterialCurrentSource` no longer accepts a delivery request and therefore cannot
  reuse its deadline. Source-catalog and outbox metadata admission now derive the same fresh
  Authority-time five-minute bound as delivery attempts, and use it for both the metadata seal
  deadline and predecessor grace without reauthorizing the already receipt-backed custody effect.
  Both production schema arms use that narrower interface. The focused retained-material group
  passes **14/14**, including rotation invoked after the historical ingress deadline; the full
  primary suite passes **4779/4779** in 86.23 seconds. Canonical `prodbox dev check` passes with
  pinned formatting, HLint `No hints`, generated/documentation policy, and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:91766b241d7cced4e8acdac96ed2bf91f163ffb946606485cf6cf1ef01be20d6`.
  Rerun documentation-inclusive canonical validation, then live `pre-1`; neither
  retained-delivery counterexample is live-closed yet. No preactivation cycle has passed, no
  artifact or witness exists, and the legacy public writer remains sole.
- The documentation-inclusive gate passes, then the live retry builds local image
  `sha256:eedd04e1441795fa6bd009bdc985e00b6fb14cfb771dcd9f6fb508f15d351fd1` in 1001.0
  seconds, publishes registry manifest
  `sha256:8750ae97ee9d09864b7bfd3adf48332c3ccdcba2acdec38ad76e52526446b86d`, and imports OCI
  manifest `sha256:239de4659c67ae97fe4cc8c835fb6452a265f343ac4eda37533053579f337bfe` in 107.3
  seconds. It crosses `RetainedSealDeadlineExpired`, live-closing the fresh source-metadata deadline
  correction, then refuses at `RetainedDeliverySourceMismatch`. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-LEGACY-SOURCE-RECEIPT-CORRECTION-2026-09-01` owns the exact
  legacy repair. The retained-material v1 catalog was written before the Target receipt carried its
  HMAC source receipt: its current source and expired pending delivery therefore use the
  permit/source operation as the source receipt. `sourceMatchesSeal` compares only operation and
  generation, so source reconciliation returns `RetainedSealAlreadyCommitted` for that legacy
  current value and the coordinator accepts it; exact delivery admission then correctly rejects the
  recovered HMAC receipt. Repair must be an explicit narrow Authority transition admitted only for
  this legacy shape: same generation, operation, ciphertext digest, commitment, and Vault version;
  old receipt exactly equal to the operation; different observed receipt; no completed delivery
  using the old receipt. Exact replay is idempotent. An expired unobserved pending delivery may
  advance atomically to its deterministic successor using the corrected current receipt only after
  exact Target absence; it may not rewrite or rerun the old envelope. Candidate execution is not
  reached, exact terminal cleanup is not proved, operational credentials are preserved, no
  qualification artifact or activation witness exists, and the legacy public writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-RETAINED-LEGACY-SOURCE-RECEIPT-CORRECTION-2026-09-01` is complete.
  The explicit `ObserveLegacyRetainedMaterialSourceReceiptCorrection` transition admits only a
  current `receipt == operation` source, an observed different receipt with otherwise exact
  generation/operation/ciphertext/commitment/Vault-version identity and non-regressing observation
  time, and no completed delivery referencing the legacy receipt. It changes only current metadata,
  is idempotent after response loss, and is retried by the coordinator with the same observation.
  Request matching recognizes the old pending envelope without rewriting it. Only exact Target
  absence after strict expiry reaches `ReplaceExpiredRetainedMaterialDelivery`; that transition may
  advance the source receipt only from the legacy operation value to the exact corrected current
  receipt while retaining deterministic successor identity, target, generation, attestation, fresh
  key, and fresh deadline. The focused retained-material group passes **16/16**, the adjacent
  external-material group **25/25**, and the full primary suite **4781/4781** in 84.68 seconds.
  Canonical `prodbox dev check` passes with pinned formatting, HLint `No hints`,
  generated/documentation policy, and warning-clean all-target compilation. The synchronized
  executable is exact at
  `sha256:2c7c8a8a93dd1bcb2bad9bbb5559a166a78dc9f90743ebdd73194d6886389ff3`.
  Rerun documentation-inclusive canonical validation, then live `pre-1`; the legacy receipt and
  delivery-successor counterexamples remain live-open. No preactivation cycle has passed, no
  artifact or witness exists, and the legacy public writer remains sole.
- The corrected live retry uses local image
  `sha256:8be228601ebbc8d5d79e9d9d40abe24d93c9cdf7c3e98c091418497966c9fb86`, registry
  manifest `sha256:e14767051212f786d07c40fee542797f0f2b240ee0c926ed7ad2c1bc181b42bf`, and OCI
  manifest `sha256:588203910fbab1c2893ce60ccc457dd77634ed32b3a68533e5090681be61f822`.
  It crosses the legacy source-receipt correction and persists the exact deterministic delivery
  successor, live-closing both retained counterexamples. The successor effect does not yield an
  observable Target receipt. An immediate supported replay observes exact absence but exits at the
  intentional five-minute safety hold, `retained delivery remains pending until its absolute
  deadline`; the focused recovery cases prove this arm does not rerun the effect. This is a bounded
  recovery wait, not a new semantic counterexample: resume the same `pre-1` command after the
  persisted deadline so the Authority can replace that successor with its next deterministic
  successor. Exact terminal cleanup is not proved, operational credentials are preserved, no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- The post-deadline replay advances to the next exact successor and executes it, live-closing the
  bounded recovery hold. It then refuses at
  `TargetMaterializationIntentIssueFailed (TargetIntentAuthorityTransportFailed ... HttpTimeout
  "connection timeout")`. Read-back of the deployed `lifecycle-authority-isolation` generation 2
  policy proves the causal route: retained delivery constructs an authenticated
  `localAuthorityTransport` to `lifecycle-authority.lifecycle-authority.svc`, ingress admits the
  namespace-local caller, but the default-deny egress inventory has no same-Pod Service lane. The
  zero-restart Ready Authority Pod therefore cannot reach its own Target-intent route. Stable
  counterexample
  `AWS-HARNESS-ACME-EAB-LIFECYCLE-AUTHORITY-SELF-ROUTE-EGRESS-DENIED-2026-09-01` licenses only an
  exact namespace-plus-name-plus-release self egress peer on the control-plane port, with a
  canonical gate and focused regression. The Target worker is not created, exact terminal cleanup
  is not proved, operational credentials are preserved, no qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-LIFECYCLE-AUTHORITY-SELF-ROUTE-EGRESS-DENIED-2026-09-01` is complete.
  The Lifecycle Authority NetworkPolicy now admits its authenticated Service route only back to a
  Pod jointly selected by the exact namespace, `prodbox-lifecycle-authority` name, and Helm release
  instance on the control-plane port. The canonical checker rejects removal or widening of that
  exact shape. The focused isolated-Provider/Authority policy group passes **26/26** and the full
  primary suite passes **4781/4781** in 85.74 seconds. Canonical `prodbox dev check` and `git diff
  --check` pass; the synchronized executable is exact at
  `sha256:7418869cd5d9c397ba11bd0f28861e33aa46e30f4e7bb95124ffc4f027846847`.
  Rerun documentation-inclusive canonical validation, then live `pre-1`; the self-route
  counterexample is not live-closed by local evidence. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The documentation-inclusive retry builds local image
  `sha256:36ed5d849ab6e441ba71971e430ebfe6f00329e82e49785c4399e1f28a62166c` in 1021.0
  seconds, publishes registry manifest
  `sha256:fd4d4aa041f60abf68893e6b17a0b106846b8b2d1af10086c3b2d458be5c977d`, and imports OCI
  manifest `sha256:6495759e4700dbb86398f41ac356ae32b251f32d5111cb76a042a7fc4a136091`
  in 100.8 seconds. It crosses the prior connection timeout and receives the authenticated
  Target-intent refusal `receipt-digest-mismatch`, live-closing the exact self-route policy
  counterexample. Stable counterexample
  `AWS-HARNESS-ACME-EAB-TARGET-INTENT-RECEIPT-DIGEST-SUBSTITUTION-2026-09-01` owns the next
  boundary. The delivery request's attestation field is the exact external-material custody-receipt
  digest retained by the prepared Target intent, but
  `productionRetainedMaterialDeliveryWithKeyPair` substitutes `sha256TargetValueDigest opening`
  when asking the Authority to issue that intent. The opening digest remains worker material
  binding and cannot stand in for the prepared receipt. Project the exact validated
  delivery-attestation digest into `TargetMaterializationRequest` while retaining the distinct
  envelope/opening digests for their existing purposes. The Target worker is not created, exact
  terminal cleanup is not proved, operational credentials are preserved, no qualification artifact
  or activation witness exists, no preactivation cycle has passed, and the legacy public writer
  remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-TARGET-INTENT-RECEIPT-DIGEST-SUBSTITUTION-2026-09-01` is complete.
  `retainedTargetIntentReceiptDigest` validates and projects the durable delivery attestation into
  Target-intent issuance; the opening is still passed only to the worker materializer, and the
  rewrapped envelope keeps its separately checked digest. The focused retained-material group
  passes **17/17**, the adjacent external-material group passes **25/25**, and the full primary
  suite passes **4782/4782** in 86.67 seconds. Canonical `prodbox dev check` and `git diff --check`
  pass; the synchronized executable is exact at
  `sha256:75f76ef8f87a9599adcf756b02e1b1d8ca53a31a4c88c1c1781d66f4d42504f6`.
  Rerun documentation-inclusive canonical validation, then live `pre-1`; the digest-substitution
  counterexample is not live-closed by local evidence. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The corrected live retry builds local image
  `sha256:fb2661df9441f3ac639e947cccce84b987fbb6dddcde2bba604f0cf3728c2cf7`, publishes registry
  manifest `sha256:150fa1c7e868b57ed6c7c985df1ed53c2c9564eb293ee06c26a5aa9445c7e220`, and imports OCI
  manifest `sha256:f2f5fc07a3a966f75e71f879acf23f2db9a5a8d54b4143f77ec7e725d1354028`
  in 108.4 seconds. It crosses receipt-digest validation and receives the authenticated
  Target-intent refusal `intent-deadline-reached`, live-closing the digest-substitution
  counterexample. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-TARGET-INTENT-DEADLINE-EXPIRED-2026-09-01` owns the next boundary.
  The recovered delivery successor carries a fresh delivery deadline, but the Target-intent issuer
  still projects the expired external-ingress intent deadline into the authorized prepared intent.
  Exact terminal cleanup is not proved, operational credentials are preserved, no qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-RETAINED-TARGET-INTENT-DEADLINE-EXPIRED-2026-09-01` is complete.
  ACME Target-intent issuance now derives the delivery outbox coordinate from the registered Agent
  and selects exactly one pending operation whose source receipt, target, generation, and prepared
  custody-receipt attestation match the authenticated request. Its signed deadline is that
  persisted delivery successor's fresh deadline; the completed external-ingress deadline is not
  consulted. The focused retained-material group passes **18/18**, the adjacent external-material
  group passes **25/25**, and the full primary suite passes **4783/4783** in 85.05 seconds.
  Canonical `prodbox dev check` and `git diff --check` pass; the synchronized executable is exact at
  `sha256:9d2db6efc68d3e6b6f131b20d7057086e8352d61d9566beffe100cd90d5fab61`.
  Rerun documentation-inclusive canonical validation, then live `pre-1`; the retained-deadline
  counterexample is not live-closed by local evidence. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The documentation-inclusive live retry builds local image
  `sha256:a762a0c152e1419ee9206bdd30ee0ca254bce899b94f57b3076fd60dec7dbaeb` in 1013.8
  seconds, publishes registry manifest
  `sha256:c6594615f605055fbc04ea4830eebe498c1d0ac2aec39bfeda365d636b2ea878`, and imports OCI
  manifest `sha256:ac89be4390dff7844835182c7abdfc91d69c6f9c0aff6b2eb6ee78eee91f9c96`
  in 110.6 seconds. It crosses the expired Target-intent refusal, live-closing the
  retained-deadline counterexample, then the outer authenticated retained-delivery call ends at
  `ControlPlaneTransportFailed (HttpTimeout "response timeout")` before an observable delivery
  receipt. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-DELIVERY-RESPONSE-BUDGET-2026-09-02` owns this next boundary.
  The Authority-side delivery now includes the bounded rewrap, Target-intent, one-shot worker, and
  read-back path, while its caller still exhausts the generic transport response budget. Exact
  terminal cleanup is not proved, operational credentials are preserved, no qualification artifact
  or activation witness exists, no preactivation cycle has passed, and the legacy public writer
  remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-RETAINED-DELIVERY-RESPONSE-BUDGET-2026-09-02` is complete. One typed
  capacity constant now binds the persisted five-minute delivery lifetime to 30 seconds of
  response overhead. Only the host EAB and in-cluster SES retained-delivery clients consume the
  resulting 330-second timeout; the ordinary host Authority route remains 30 seconds and the
  worker's ordinary Authority route remains the generic 10 seconds. The focused budget regression
  passes **1/1**, the retained-material group passes **18/18**, the adjacent external-material
  group passes **25/25**, and the full primary suite passes **4784/4784** in 85.67 seconds.
  Canonical `prodbox dev check` and `git diff --check` pass; the synchronized executable is exact at
  `sha256:e2269d9f3c859dda994781a12f6c26b18a4765a7a7697cc1de60136e3597316e`.
  Documentation-inclusive canonical validation also passes. Rerun live `pre-1`; the
  response-budget counterexample is not live-closed by local evidence. No qualification artifact
  or activation witness exists, no preactivation cycle has passed, and the legacy public writer
  remains sole.
- The documentation-inclusive live retry builds local image
  `sha256:2196a24ccd7205a95bcc45bc21b0a096867216c33a3cdf107b7cbe1045b701ca` in 1015.3
  seconds, publishes registry manifest
  `sha256:6b3a67fa63aa7e5d2093a2a81cae23f20e66ebe497853b3c5b71c9fd7fa8dfb5`, and imports OCI
  manifest `sha256:d7d9a08d767180701c2adfee89e3b09d130f8a1aa585a221fb95b2f8f6aa92e0`
  in 109.8 seconds. The retained-delivery request remains open beyond the superseded 30-second
  budget and returns the authenticated refusal
  `TargetMaterializationWorkerFailed TargetWorkerCoordinatorWorkloadAbsent`, live-closing the
  response-budget counterexample. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-TARGET-WORKER-WORKLOAD-ABSENT-2026-09-02` owns this next
  boundary. Exact terminal cleanup is not proved, operational credentials are preserved, no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-RETAINED-TARGET-WORKER-WORKLOAD-ABSENT-2026-09-02` is complete.
  Read-only live evidence proves the exact Target worker Job and Pod were created, scheduled, and
  started at `2026-09-02T05:23:35Z`/`05:23:36Z`, remained present until their bounded deadline,
  and were deleted at `05:26:35Z`; the reported clean absence was therefore a false terminal
  classification. The coordinator now retains the last typed observation failure across clean
  absence retries and returns it if the final sample is absent; an all-clean-absence history still
  reports workload absence, while an observed result or current failure remains authoritative.
  The focused Target-worker suite passes **35/35** and the full primary suite passes **4785/4785**
  in 85.53 seconds. Canonical `prodbox dev check` and `git diff --check` pass; the synchronized
  executable is exact at
  `sha256:c8b80bc44d397c19bc2d9ba08dd6b0ea2e0ee614e938b3f548028c4c105925e4`.
  Documentation-inclusive canonical validation also passes. Rerun live `pre-1` to expose the
  exact prior observation failure. The workload-absence counterexample is not live-closed by local
  evidence; no qualification artifact or activation witness exists, no preactivation cycle has
  passed, and the legacy public writer remains sole.
- The corrected live retry builds local image
  `sha256:4ffe731e997d775a8af4d925cf5643f4c8c6a27267acc481dd935c21d4cceb3d` in 1009.9
  seconds, publishes registry manifest
  `sha256:83b7c943cca81bb0ce85684eec618c19eb4dfd6005fc376f00638d021aabde75`, and imports OCI
  manifest `sha256:511f1cabf105c1759421812dd4eca05756f3f33da62f0178507b915e979bd0ae`
  in 108.5 seconds. It returns the retained prior typed observation failure
  `TargetWorkerCoordinatorObservationFailed "Target worker image digest mismatch"`, live-closing
  the false workload-absence counterexample. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-TARGET-WORKER-IMAGE-DIGEST-MISMATCH-2026-09-02` owns the
  next boundary. Exact terminal cleanup is not proved, operational credentials are preserved, no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-RETAINED-TARGET-WORKER-IMAGE-DIGEST-MISMATCH-2026-09-02` is
  complete. Read-only evidence shows the deployed Target Agent identity and Docker-local runtime
  token were the config identity
  `sha256:4ffe731e997d775a8af4d925cf5643f4c8c6a27267acc481dd935c21d4cceb3d`, while
  the exact published repository manifest was
  `sha256:83b7c943cca81bb0ce85684eec618c19eb4dfd6005fc376f00638d021aabde75`;
  the downstream Job's `Always`-pull observation requires the latter. One typed resolver now
  derives the registered Target Agent identity from the independently selected repository
  manifest in both deployed control-plane values and first-reconcile permit construction. The
  Docker-local image ID remains only the Pod rollout trigger, and the observed declared tag remains
  only the pull address. The focused substitution regression passes **1/1** and the full primary
  suite passes **4786/4786** in 84.52 seconds. Canonical `prodbox dev check`, documentation lint,
  and `git diff --check` pass; the synchronized executable is exact at
  `sha256:0d891541c75bc0b61926b4466c9be6828969bc76e1f4fc8e1537af4f99c935aa`.
  Rerun live `pre-1`; the image-digest counterexample is not live-closed by local evidence. No
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- The manifest-identity live retry builds local image
  `sha256:672cdf751ca108fe7fdce185f0f2710cfe69c26a1c2d245d411bf27d09464ff6` in 1013.1
  seconds, publishes registry manifest
  `sha256:5c61858c84773f6b1523740459cbe4d54a9f70d50e0d036ed86aa13a664850c6`, and imports OCI
  manifest `sha256:4f2cc59fe5beb4a64b8b5d6fe029d68fa462a20fb1053e86b2ecde671f62f42d`
  in 117.9 seconds. It crosses Target-worker runtime image attestation, live-closing the image-
  digest counterexample, and reaches execution-permit issuance before returning
  `TargetIntentAuthorityUnavailable "target-trust-install-unavailable/client/response-codec/invalid"`.
  Stable counterexample
  `AWS-HARNESS-ACME-EAB-TARGET-TRUST-INSTALL-RESPONSE-CODEC-2026-09-02` owns this next
  boundary. Exact terminal cleanup is not proved, operational credentials are preserved, no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- Code-local closure for
  `AWS-HARNESS-ACME-EAB-TARGET-TRUST-INSTALL-RESPONSE-CODEC-2026-09-02` is implemented.
  The Target-trust decoder now preserves only the closed HTTP status class for a codec-invalid
  non-server response and, for a codec-invalid server response, the existing exact static
  authenticated-role response classification or `other`. It retains neither response bytes nor a
  numeric status and changes no trust installation, CAS, read-back, response, retry, cleanup,
  remint, permit, journal, or delivery behavior. The focused Sprint-2.116 regression passes
  **1/1**; full primary validation passes **4786/4786** in 85.98 seconds. Canonical `prodbox dev
  check`, documentation lint, and `git diff --check` pass; the synchronized executable is exact at
  `sha256:1b8ca067de7da05e0718a00fe29697cb82d19794925068c05a03c3890894978f`. A live
  `pre-1` replay remains required to expose the exact closed cause and live-close the
  counterexample. No qualification artifact or activation witness exists, no preactivation cycle
  has passed, and the legacy public writer remains sole.
- The status-aware live retry builds local image
  `sha256:a1a7899b835fbee52e84ec6cda2bb8d354cef92e797da132e3da345783036d90` in 1009.4
  seconds, publishes registry manifest
  `sha256:77a45781258525502a2a42c447c930e88b4764bee689fa49cccbdf273fd6cef3`, and imports
  OCI manifest `sha256:c22b3fde8cd8bf7c28f67aaf97db0d1a49cf8673f120add37bfd906fa4b6457a`
  in 112.1 seconds. The retained root session, baseline digest, and storage generation remain
  exact; the run reaches Target trust installation and returns the exact fixed authenticated-role
  cause
  `target-trust-install-unavailable/client/response-codec/invalid/status/server/replay-capacity-exhausted`,
  live-closing the generic response-codec counterexample. Stable counterexample
  `AWS-HARNESS-ACME-EAB-TARGET-TRUST-INSTALL-REPLAY-CAPACITY-EXHAUSTED-2026-09-02`
  owns the next boundary. The command exits 1, exact terminal cleanup is not proved, and
  operational credentials are preserved. No qualification artifact or activation witness exists,
  no preactivation cycle has passed, and the legacy public writer remains sole.
- Source closure proves the complete Target Agent preflight envelope is five requests: one provider
  credential observation, one committed external-material source recovery observation, then the
  retained delivery's Target observation, rewrap, and trust installation. The correction derives
  capacity `2 * 5 = 10` for one whole attempt and its immediate unchanged retry while the earlier
  requests remain inside the deadline-plus-skew horizon. It also gives only this role a 24 MiB
  encoded projection bound so ten accepted 2 MiB responses plus metadata fit; TLS Retention and
  Provider Worker remain at generic capacity four/12 MiB. The retained codec advances to v7 and
  admits canonical v6/capacity-four state under the widened Target limits without dropping its
  non-empty entries; response-size/skew drift, shrink, corruption, and clearing remain refused. The
  focused authenticated-transport suite passes **35/35**, including the exact fourth/fifth refusal
  trace, two complete attempt envelopes, non-empty v6-to-v7 migration, and a ten-maximum-response
  projection that exceeds the old 12 MiB ceiling but fits and round-trips under 24 MiB. Full primary
  validation passes **4786/4786** in 87.57 seconds; canonical `prodbox dev check` passes policy,
  formatting, HLint (`No hints`), and warning-clean all-target compilation. Documentation lint,
  generated-doc check, and `git diff --check` pass, and the synchronized executable is exact at
  `sha256:1e84d716b3fba16052e31d3e7f2cac16c3fe9776aab0b77e01a6434f3147aec8`. A live exact
  `pre-1` replay remains pending. No qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- The corrected live `pre-1` replay builds local image
  `sha256:3334b9937d5ce0bda911cee41d888021f297b78f0039fec9614c4c155d5eba12` in
  1022.3 seconds, publishes registry manifest
  `sha256:e0ac098341fe329ab5258125c32f5a8fa7aee72c264285f3a457a639aacc0341`, and
  imports OCI manifest
  `sha256:dc7384ca8f12da899b9e3ca0e3eff7020c35a1481bbcf520375a2c12d4e3e587` in
  107.0 seconds. Managed retention removes only the superseded prior image. Root session
  `root-session-9c54db6ad0a352d81a4313f7f2613735c056a2b635618cc095bba021a6b21a5b`, baseline
  digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`, and
  storage generation
  `vault-a290544ececcff87892b19c03dcbf1a06ad3eb800614aaf413af5b81f42ad422` remain
  exact. The run reconciles Target Agent, Lifecycle Authority, post-unseal handoff, and Authority
  Backup, then reports that the lifecycle-provider credential is current at generation 2. This
  live-closes
  `AWS-HARNESS-ACME-EAB-TARGET-TRUST-INSTALL-REPLAY-CAPACITY-EXHAUSTED-2026-09-02`.
  The later AWS-credential validation reaches the authenticated Authority/Provider lane but the
  Authority's Provider client cannot resolve
  `provider-worker.provider-worker.svc.cluster.local`; the exact closed terminal is
  `AuthorityProviderRemoteRefused 503 "ProviderWorkerTransportFailed
  (AuthenticatedClientTransportFailed (ControlPlaneTransportFailed (HttpConnectionFailure ... does
  not exist (Name or service not known))))"`. Stable counterexample
  `AWS-HARNESS-PROVIDER-WORKER-SERVICE-DNS-UNAVAILABLE-2026-09-02` owns that next boundary.
  The command exits 1, exact terminal cleanup is not proved, and operational credentials are
  preserved. No qualification artifact or activation witness exists, no preactivation cycle has
  passed, and the legacy public writer remains sole.
- Source diagnosis proves the endpoint identity is canonical and the Service belongs to the
  ordinary reconcile graph, but the harness proceeded directly from its deliberately Provider-free
  pre-credential bootstrap floor to AWS prerequisites. The code-local correction preserves that
  floor, repairs the Lifecycle-provider generation, then re-enters ordinary local-only `cluster
  reconcile` before ACME EAB ingress or `aws_credentials_valid`. That graph-rooted reconcile
  enables neither edge nor AWS-target mutation and retains the normal Provider deep-readiness gate;
  pure IAM-only harness suites still create no runtime. Unit coverage fixes the exact command
  selection for both suite classes. Haskell formatting/HLint passes with `No hints`, `git diff
  --check` passes, the full primary suite passes **4786/4786** in 87.73 seconds, and canonical
  `prodbox dev check` passes. The synchronized executable is exact at
  `sha256:0610acc3476b0b073a1b1b44c0819807a20576a6f113228f5deba072c0df8898`. A live
  `pre-1` replay remains pending. No qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- The corrected live `pre-1` replay builds local image
  `sha256:1245c499a0a71f714cd3579c5b16f6005623f1d6cb695d927f87154faca02f13` in 1004.8
  seconds, publishes registry manifest
  `sha256:4c1e12edeafd8645d2b4614bf993e69dd1656ce11a8ebd59381526768d3e8a14`, and imports
  OCI manifest `sha256:48c0a3298e42730a3794b3992224f2b1fa1669874b1ec356c0454b82d2249c5e`
  in 112.2 seconds. Managed retention removes only the prior manifest/image. Root session
  `root-session-9c54db6ad0a352d81a4313f7f2613735c056a2b635618cc095bba021a6b21a5b`, baseline
  digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`, and
  storage generation
  `vault-a290544ececcff87892b19c03dcbf1a06ad3eb800614aaf413af5b81f42ad422` remain
  exact. Credential generation 2 is confirmed before the new ordinary local-only reconcile; that
  reconcile installs Provider Worker, passes its strict deep readiness, and advances through
  Gateway and TLS Retention, live-closing
  `AWS-HARNESS-PROVIDER-WORKER-SERVICE-DNS-UNAVAILABLE-2026-09-02`. The following existing
  `--with-edge` runbook creates the managed DNS01/EAB materializer resources but exits 1 with exact
  terminal `ACME EAB materializer did not complete.` Stable counterexample
  `AWS-HARNESS-ACME-EAB-MATERIALIZER-NOT-COMPLETE-2026-09-02` owns this next boundary.
  Exact terminal cleanup is not proved and operational credentials are preserved. No qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole. Diagnose the exact Job/Pod observation and logs before changing its
  lifecycle.
- The supported diagnostic rerun reproduces one failed Pod with both init and main containers
  started; the retained Job reports `BackoffLimitExceeded`, while the sibling home-DNS01 Job
  completes. Before foreground cleanup, the exact main-container terminal is `grep: bad regex
  '^[A-Za-z0-9._~-]{1,512}$': Invalid contents of {}`, followed by the closed unsupported-shape
  message. The curl image's grep rejects the repetition bound itself, so it misclassifies every
  valid key ID. The code-local correction separates the same 1..512 contract into nonempty and
  POSIX-shell `${#key_id}` upper-bound checks, then applies an unbounded
  allowed-ASCII-character regex; it neither widens the accepted alphabet nor exposes the key ID.
  The rendered-manifest regression pins the new length and alphabet checks and excludes the invalid
  bounded regex. Formatting and validation remain pending before another live `pre-1`; the legacy
  public writer remains sole.
- The first full primary rerun compiles the correction but reports **1/4786** failed: the new test
  searched JSON-encoded manifest text for an unescaped double-quoted shell fragment. Production
  rendering is exact in the failure output. The test now pins `${#key_id}` and `-le 512`
  independently so JSON string escaping cannot masquerade as a command-shape failure; the alphabet
  and old-bound assertions are unchanged. The corrected focused regression passes **1/1**, Haskell
  formatting/HLint passes with `No hints`, `git diff --check` passes, and the full primary suite
  passes **4786/4786** in 88.50 seconds. Canonical `prodbox dev check` passes, and the synchronized
  executable is exact at
  `sha256:e675de068683a1177c472a1c0716e19cedb749b743acf8c4726b5c0437a4b900`. A live
  `pre-1` replay remains pending.
- That replay builds local runtime image
  `sha256:d2d8f884049bae42e9d7a7ada872692e63c678d67dfed012bdb84c3e0626faf2`, publishes
  registry manifest `sha256:15195e7bed16b94bca561e4271f3c6fe80a731e35242edfaa1b6d501eccc6718`,
  and imports OCI manifest
  `sha256:9134409efb1df86a4b8bcee02b74d16d9bc7b50e3e411661d626e300e8d501f4`.
  Managed retention removes only the superseded image and manifest. Root session
  `root-session-9c54db6ad0a352d81a4313f7f2613735c056a2b635618cc095bba021a6b21a5b`, baseline
  digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`, storage
  generation `vault-a290544ececcff87892b19c03dcbf1a06ad3eb800614aaf413af5b81f42ad422`, and
  Lifecycle-provider credential generation 2 remain exact. The post-credential ordinary reconcile
  restores Provider Worker, Gateway, and TLS Retention. The corrected EAB materializer completes and
  `zerossl-dns01` reaches Ready, live-closing
  `AWS-HARNESS-ACME-EAB-MATERIALIZER-NOT-COMPLETE-2026-09-02`. The next exact failure is
  `TlsWorkflowHomeAgentFailed (TlsTargetAgentClientHttpStatus 401)`: the host TLS workflow signs its
  direct home Target Agent request as `CallerOperatorCli`, while all six Target TLS routes admit
  only `CallerService LifecycleAuthorityRuntime`. Stable counterexample
  `HOME-TLS-WORKFLOW-BYPASSES-LIFECYCLE-AUTHORITY-2026-09-02` owns the routing correction. Target
  trust must not widen to the operator; route the workflow through the retained Authority as the
  stable TLS doctrine requires. The command exits 1. Its restore aggregate also fails VS Code
  deletion, WebSocket restoration because Redis remains unscheduled under insufficient CPU, and
  public-edge readiness, so exact terminal cleanup is not proved and operational credentials are
  preserved. No qualification artifact or activation witness exists, no preactivation cycle has
  passed, and the legacy public writer remains sole.
- Code-local closure for `HOME-TLS-WORKFLOW-BYPASSES-LIFECYCLE-AUTHORITY-2026-09-02` is
  complete. The new bounded Authority workflow endpoint accepts only the closed retain/restore
  request over stable authentication route code 60. Home ChartPlatform submits that request to the
  retained Authority; Authority self-authenticates observe/promote state calls and alone authenticates
  to the home Target Agent and TLS Retention Adapter. All six Target TLS routes remain exact
  `CallerService LifecycleAuthorityRuntime` lanes; operator and harness identities cannot call them.
  The Authority and Adapter NetworkPolicies admit the matching exact namespace-plus-Pod lanes and no
  namespace-wide cross-role ingress. The authentication suites pass **34/34** and **36/36**; the
  complete primary suite passes **4789/4789**, including the workflow codec/status, trust-topology,
  stable-route-code, policy, and exhaustive startup-cause regressions. The documentation-inclusive
  canonical `prodbox dev check` also passes with HLint `No hints`, warning-clean all-target
  compilation, generated/documentation policy, and diff hygiene. The synchronized executable is
  exact at `sha256:a7142a4a08ace977c1536bc337abab116f25fc8fa3d465adebafcdf26c32fc80`.
  The unchanged live `pre-1` replay remains pending. No qualification artifact or
  activation witness exists, no preactivation cycle has passed, and the legacy public writer remains
  sole.
- That replay builds local runtime image
  `sha256:5339ad0c4dc08d0f8f3e58b748403ace2ff78a656e2ed0f6913e028e4225926b`, publishes
  registry manifest `sha256:620a9243925d64b2f1b61369ec302179a32ee86f751ff5a6112091e9d7feb360`, and imports
  OCI manifest `sha256:93a468947efa4ada5003f67a5245984248443f0f60488f6985b95c5e56333bd1`.
  It stops before the corrected TLS boundary, AWS harness setup, or candidate execution while
  unsealing Vault. The exact `bootstrap-secret-worker` Pod requests `250m / 256Mi`, but the node has
  `6945m` CPU requests against `7000m` allocatable; Kubernetes leaves the Pod without container
  status and records `0/1 nodes are available: 1 Insufficient cpu`. Host attestation retries that
  non-started observation for its complete bounded window and then fails closed; postflight deletes
  the one-shot Pod. The typed resource plan contains the standing `bootstrap-broker` but no
  one-shot secret-worker draw, so the preceding host-capacity success did not reserve capacity for
  the operation it immediately invoked. Stable counterexample
  `BOOTSTRAP-SECRET-WORKER-ABSENT-FROM-CAPACITY-PLAN-2026-09-02` owns this exact scheduler boundary.
  Close it with a repository-owned zero-growth resource-envelope reproducer and explicit one-shot
  capacity projected into the production Pod; do not weaken attestation, lengthen its already
  exhausted wait, invent host capacity, or reduce the established gateway sufficiency envelope.
  No qualification artifact or activation witness exists, no preactivation cycle has passed, and
  the legacy public writer remains sole.
- Code-local closure for
  `BOOTSTRAP-SECRET-WORKER-ABSENT-FROM-CAPACITY-PLAN-2026-09-02` is complete without increasing the
  topology-normalized host envelope. The stable repository-owned reproducer holds host capacity,
  eviction, standing load, gateway sufficiency, and every resource axis constant. Its exact
  CPU/memory/ephemeral/durable mapping is superseded
  `rke2_reserved (1000m, 2048Mi, 10240Mi, 1024Mi) + zero one-shot draw` to replacement
  `rke2_reserved (500m, 1536Mi, 9728Mi, 1024Mi) + one exclusive-window maximum
  (500m, 512Mi, 512Mi, 0)`. The production plan explicitly carries one
  `bootstrap-secret-worker` and two `credential-provisioner-secret-workers` replicas in shared
  window `one-shot-secret-workers`. Both derive the same hidden Guaranteed envelope
  `250m / 256Mi / 256Mi ephemeral / 0 durable`; Bootstrap, Credential Provisioner, Target Secret,
  and AWS-admin worker manifests render that common value. Production settings reject every
  missing, partial, renamed, resized, non-Guaranteed, or non-exclusive variant. The AWS harness
  refreshes stale capacity only for an exact harness-owned config and preserves a complete
  operator-owned config. The reproducer pins old fail (`6945m + 250m > 7000m`) and replacement
  pass under the same causal schedule (`6945m + 300m restored Redis/WebSocket + 250m < 7500m`).
  Kubelet reservation exposes the 7500m node allocatable; the compiler separately subtracts its
  unchanged 500m eviction budget. Systemd containment remains at its prior two-worker peak, the
  attestation window is unchanged, and the established gateway envelope is unchanged. The complete
  primary suite passes **4791/4791**, auxiliaries pass **27/34/36**, and canonical `prodbox dev
  check` exits 0 with Fourmolu, HLint `No hints`, conformance, and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:b3e8d9ef22d94bb59f20f89e8c21c1e51cc9c09e04c3d80bfe7e3067817851e8`.
- The unchanged live `pre-1` replay proves the capacity correction. It writes the kubelet
  guardrail, restarts RKE2, and independently reads `8` CPU capacity / `7500m` allocatable. It
  builds local runtime image
  `sha256:79673fcd37a2a596d6df57785898b5c1dd191f55e56246790a01032f52f5a57a`, publishes registry
  manifest `sha256:0ebd0ca830f448a9b889c0085377a207bf1fd77c53d6bd3d7af2f6b4eb2092a1`, and imports OCI
  manifest `sha256:431f4877205c5ead0a25b083223a4738d7467b5704033257218951817bd26f28`. The bootstrap
  worker starts, Vault unseal succeeds, the retained root session, baseline digest, and storage
  generation stay exact, credential generation 2 stays current, and home reconcile crosses
  Provider Worker, Gateway, TLS Retention, both secret materializers, and Ready
  `zerossl-dns01`. The next candidate failure is
  `TlsRetentionWorkflowAuthorityHomeAgentUnavailable` during chart cleanup. Stable counterexample
  `TLS-WORKFLOW-AUTHORITY-HOME-AGENT-UNAVAILABLE-2026-09-02` owns that exact Authority-workflow
  availability boundary; do not restore the removed direct operator-to-Target call or widen Target
  trust. The restore aggregate separately fails VS Code deletion/reconcile against the three
  existing Percona PVCs and public-edge readiness because Gateway-DNS write authority is not ready.
  The command exits 1 and preserves operational credentials because exact terminal cleanup is not
  proved. No qualification artifact or activation witness exists, no preactivation cycle has
  passed, and the legacy public writer remains sole.
- The code-local diagnostic for
  `TLS-WORKFLOW-AUTHORITY-HOME-AGENT-UNAVAILABLE-2026-09-02` is complete without changing replay
  capacity, TLS effects, retry, or trust. `TlsTargetAgentClient` classifies only an exact static
  authenticated-role HTTP status/body pair into the closed observation; arbitrary response bytes
  remain `other` and never enter the error or Authority response. The Authority workflow adds
  distinct home/selected Target replay-capacity constructors and preserves the existing
  availability projections for every other cause. The focused exact-pair/payload-redaction
  regression passes **1/1**, the complete primary suite passes **4792/4792**, auxiliaries pass
  **27/34/36**, and canonical `prodbox dev check` exits 0 with Fourmolu, HLint `No hints`,
  conformance, and warning-clean all-target compilation. `git diff --check` passes and the
  synchronized diagnostic executable is exact at
  `sha256:e4ae6d14662c9843ee2df684f14ec639f0573bdc8ac8e0f7fbfb6cf17bcf21bc`. Rerun live
  `pre-1` unchanged to expose the exact closed Target response before changing the retained replay
  bound. No qualification artifact or activation witness exists, no preactivation cycle has
  passed, and the legacy public writer remains sole.
- The unchanged diagnostic `pre-1` replay builds local runtime image
  `sha256:bc11e162bfa19e75a4b774c878adf89b8743537eb493d1b5a08f4f870532ab2e`, publishes registry
  manifest `sha256:4978a39924b120f3b8f6ff0463a4a6f2f17c4d010f519cd6494d9698bef42767`, and imports OCI
  manifest `sha256:e185dcaa8fc5784cb81f90bfedf7bc365bf56146c20ae9aa19644505ef740d7b`; managed retention
  removes only the superseded prior runtime image. Both home reconcile passes cross Bootstrap
  Broker, Target Secret Agent, Lifecycle Authority, Authority Backup, Provider Worker, Gateway,
  TLS Retention, both secret materializers, and Ready `zerossl-dns01`. During supported-runtime
  restore, the first owned-certificate turnover still returns
  `TlsRetentionWorkflowAuthorityHomeAgentUnavailable`, not the new exact replay-capacity
  constructor. The behavior-neutral diagnostic therefore falsifies the narrow claim that an exact
  Target replay-capacity response reaches this Authority call; it does not license changing the
  replay bound. The restore aggregate again records successful Websocket, API, and Gateway
  deletion, failed VS Code deletion/reconcile against the same three discovered Percona PVCs,
  successful Gateway/API/Websocket reconcile, and failed public-edge readiness because Gateway-DNS
  write authority is not Ready. The command exits 1 and preserves operational credentials because
  exact terminal cleanup is not proved. Diagnose the deployed Authority-to-home-Agent
  transport/status path while holding capacity, TLS effects, retry, and trust constant. No
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- The next behavior-neutral diagnostic checkpoint preserves those same bounds and effects. The
  Target-intent Authority client classifies only the exact static authenticated-role status/body
  pair for a nested replay-capacity refusal before CBOR decode; all other responses remain the
  existing payload-free invalid-response cause. The Target Agent and TLS workflow runtime emit
  only closed, value-free cause tokens at their existing refusal boundaries, and an ordinary
  diagnostic-write failure cannot replace the owned workflow result. No replay capacity,
  request/response envelope, deadline, retry, trust edge, TLS effect, or worker action changes.
  The exact nested-pair/private-body-redaction regression passes **1/1**, the complete primary suite
  passes **4793/4793**, auxiliaries pass **27/34/36**, and canonical `prodbox dev check` exits 0
  with repository-pinned Fourmolu, HLint `No hints`, conformance, and warning-clean all-target
  compilation. `git diff --check` passes and the synchronized diagnostic executable is exact at
  `sha256:80adeeee8ea1cad2c23d95dae31887e83228027b4366bec8d2547b2b3668703d`. Rerun the same live
  `pre-1` unchanged and inspect only the closed deployed Target-Agent/Authority diagnostic tokens
  after terminal return; this checkpoint does not license changing either retained replay bound.
  No qualification artifact or activation witness exists, no preactivation cycle has passed, and
  the legacy public writer remains sole.
- The unchanged diagnostic live `pre-1` builds local runtime image
  `sha256:3308656686330a700b88d11dc7e5003a9489525445757424817f130a669183a6`, publishes registry
  manifest `sha256:4e85a04762909f9dd5f092dbcca4bddac34b8e04b49c290aa26782444036279b`, and imports OCI
  manifest `sha256:2efbdf2bb2c6827ddc7143d256f29d8cac4336c26a2099571b8590586120dd70`; managed retention
  removes only the superseded prior diagnostic image. Every repeated home pass preserves the exact
  Vault identities and crosses Bootstrap Broker, Target Secret Agent, Lifecycle Authority,
  Authority Backup, Provider Worker, Gateway, TLS Retention, both secret materializers, and Ready
  `zerossl-dns01`. The first owned-certificate turnover stays host-visible as
  `TlsRetentionWorkflowAuthorityHomeAgentUnavailable`, while the deployed closed diagnostics
  identify `target-one-shot/tls-prepare failure=intent/transport-failed` at Target Agent and
  `tls-retention/workflow failure=home-agent/transport-failed` at Authority; Lifecycle Authority
  receives no matching request. Read-only deployed-policy inspection proves the missing edge in
  both directions: Target Agent egress admits only DNS, Vault, and Kubernetes API, and Lifecycle
  Authority ingress omits the Target Agent namespace/principal. Stable counterexample
  `TLS-TARGET-INTENT-AUTHORITY-NETWORKPOLICY-DENY-2026-09-02` owns that exact denied authenticated
  Target-intent route. Correct only the two least-privilege NetworkPolicy arms and add an exact
  rendered-topology reproducer while holding replay capacity, envelopes, deadlines, retry, trust,
  TLS effects, and worker actions constant. The restore aggregate retains the same secondary VS
  Code three-PVC and Gateway-DNS readiness failures; exit is 1 and credentials remain preserved.
  No qualification artifact or activation witness exists, no preactivation cycle has passed, and
  the legacy public writer remains sole.
- Code-local closure for `TLS-TARGET-INTENT-AUTHORITY-NETWORKPOLICY-DENY-2026-09-02` adds exactly
  the missing two halves of the already-authenticated route: Target Agent egress selects namespace
  `lifecycle-authority`, Pod label `prodbox-lifecycle-authority`, and the value-bound TCP 8600
  control-plane port; Authority ingress selects namespace `target-secret-agent`, Pod label
  `prodbox-target-secret-agent`, and its named `lifecycle` port. The old→new topology mapping is
  `no Target→Authority policy edge` to `one exact bidirectional NetworkPolicy admission` with
  process topology, resource/load envelopes, replay capacity, deadlines, retries, trust, TLS
  effects, and worker actions unchanged. The stable reproducer passes only with both exact arms
  and replays either superseded omission as a failure (**1/1**); both charts render successfully
  with the closed selectors and port. The complete primary suite passes **4794/4794**, auxiliaries
  pass **27/34/36**, and canonical `prodbox dev check` exits 0 with repository-pinned Fourmolu,
  HLint `No hints`, conformance, and warning-clean all-target compilation. `git diff --check`
  passes and the synchronized executable remains exact at
  `sha256:80adeeee8ea1cad2c23d95dae31887e83228027b4366bec8d2547b2b3668703d`; rerun live
  `pre-1` to prove the policy edge before diagnosing or changing any later cause. No qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
- The corrected live `pre-1` reuses exact local runtime image
  `sha256:3308656686330a700b88d11dc7e5003a9489525445757424817f130a669183a6` and registry manifest
  `sha256:4e85a04762909f9dd5f092dbcca4bddac34b8e04b49c290aa26782444036279b`, then live-proves the
  topology correction: deployed Target Agent policy generation 2 contains the exact Authority
  egress arm and deployed Authority policy generation 5 contains the exact Target Agent ingress
  arm. The first owned-certificate turnover advances past intent transport and now emits
  `target-one-shot/tls-prepare failure=coordinator/attestation-failed`; the host/Authority
  projection remains the expected payload-free home-Agent unavailability. Stable counterexample
  `TLS-TARGET-WORKER-ATTESTATION-FAILED-2026-09-02` owns this next exact one-shot attestation
  boundary. Diagnose it without changing replay capacity, the now-proved policies, envelopes,
  deadlines, retry, trust, TLS effects, or worker actions. The restore aggregate again records the
  same VS Code three-PVC and Gateway-DNS readiness failures, exits 1, and preserves operational
  credentials because terminal cleanup is unproved. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The behavior-neutral diagnostic for `TLS-TARGET-WORKER-ATTESTATION-FAILED-2026-09-02` preserves
  the coordinator, observation schedule, cleanup, and all effect bounds. The existing closed
  17-constructor `TargetWorkerAttestationError` algebra has one exhaustive, payload-free token
  renderer, and only the Target Agent's already-added closed diagnostic refines
  `attestation-failed` with that token; operational error projection remains unchanged. The
  complete 17-arm vocabulary/hook regression passes **1/1**, the primary suite passes
  **4795/4795**, auxiliaries pass **27/34/36**, and canonical `prodbox dev check` exits 0 with
  repository-pinned Fourmolu, HLint `No hints`, conformance, and warning-clean all-target
  compilation. `git diff --check` passes and the synchronized diagnostic executable is exact at
  `sha256:327aff7c9f0df575afd5e43e8a8d1423f55f65b4d4427d392a0242945d9d74bd`. Rerun live
  `pre-1` unchanged to identify the exact attestation arm before changing timing or worker
  behavior. No qualification artifact or activation witness exists, no preactivation cycle has
  passed, and the legacy public writer remains sole.
- The unchanged diagnostic live `pre-1` builds local runtime image
  `sha256:47cda70bd0f278b2372989db5c03acfbb8845481997d55a9fd12dadaaef1b1b4`, publishes registry
  manifest `sha256:5452befa761e9c31c603b580a3054f56454df7c7dd3a30c2f83a3c6ebcbba391`, and imports OCI
  manifest `sha256:3f1722c9a1f1d9dd524b432ba563090edaf7d69e7980772c87c4d1a254558db9`. The first
  owned-certificate turnover stays host-visible as
  `TlsRetentionWorkflowAuthorityHomeAgentUnavailable`, while the Target Agent identifies the exact
  closed arm `target-one-shot/tls-prepare failure=coordinator/attestation-failed/not-running`; the
  Authority retains its payload-free `tls-retention/workflow failure=home-agent/transport-failed`
  projection. Kubernetes events prove the exact one-shot Pod was scheduled, pulled, created, and
  started, then the Job reached `BackoffLimitExceeded`; the Pod was removed before a direct
  terminal-status or log observation. Stable counterexample
  `TLS-TARGET-WORKER-NOT-RUNNING-2026-09-02` owns this exact started-then-terminal
  worker/attestation boundary. Diagnose the worker command and exit path before changing
  observation timing: the present evidence does not license treating `not-running` as a readiness
  race. Hold the existing observation schedule, resource/load envelopes, replay capacity,
  deadlines, policies, trust, TLS effects, and worker action constant. The cleanup aggregate again
  fails VS Code delete/reconcile because the same three historical Percona PVCs are present and
  fails public-edge readiness because Gateway-DNS write authority is not ready; it exits 1 and
  preserves operational credentials because exact terminal cleanup is unproved. No qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
- Code-local closure for `TLS-TARGET-WORKER-NOT-RUNNING-2026-09-02` proves the worker process was
  not racing readiness: the rendered Job passes `--material-schema tls-prepare`, but the executable
  parser admitted only the three material-delivery schemas and exited before entering the worker
  runtime. The stable parser-boundary reproducer first failed **1/1**, expecting
  `TargetWorkerTlsPrepare` and receiving that exact three-schema refusal. The schema ADT now derives
  one exhaustive bounded enumeration, and the CLI parses the inverse of the existing canonical
  token renderer, admitting all thirteen already-implemented material/TLS/federation worker
  operations. The old→new mapping is `three parser-admitted schema tokens` to `the exact
  thirteen-constructor TargetWorkerIngressSchema vocabulary`; process topology, command arguments
  emitted by the Job, observation/cleanup schedules, resource and load envelopes, replay capacity,
  deadlines, policies, trust, TLS effects, and worker actions are unchanged. The focused reproducer
  passes **1/1**, the generated CLI output suite passes **3/3**, the complete primary suite passes
  **4796/4796**, and auxiliaries pass **27/34/36**. Canonical `prodbox dev check` passes with
  repository-pinned Fourmolu, whole-tree HLint `No hints`, conformance, generated-artifact checks,
  and warning-clean all-target compilation; `git diff --check` passes. The synchronized executable
  is exact at `sha256:43d3c8da1c03bb5dea10b283d7ce709d5dc89f03d2b899402e2651199d1ccff6`. Rerun live
  `pre-1` to prove the worker crosses parsing and expose only the next exact closed boundary. No
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- The corrected live `pre-1` reuses local runtime image
  `sha256:47d1fc71d3098fc0626009db0535dc51c2411a1150bf975b004f449749b3a34b` and registry
  manifest `sha256:31e86d899b025abf84c58c6c28db218a18ed08f9bb7cc4794e3de73b95569093`. It proves the
  parser correction: the exact `tls-prepare` one-shot Pod is scheduled, pulls that manifest,
  starts without `BackoffLimitExceeded`, and is removed by the coordinator; the Target Agent emits
  no closed failure diagnostic. Lifecycle Authority nevertheless records
  `tls-retention/workflow failure=home-agent/transport-failed` at `09:37:24.969-04:00`. The
  authenticated request necessarily reached the Agent because that handler alone created the
  observed Job, while its Lifecycle-Authority client is still the generic 10-second HTTP default
  and the Target operation owns a 15-minute authorization lifetime plus a 180-second worker
  runtime. Stable counterexample
  `TLS-TARGET-ONE-SHOT-EXCEEDS-DEFAULT-HTTP-DEADLINE-2026-09-03` owns this exact
  caller/child-schedule mismatch. Derive a Target-one-shot-only response budget from the closed
  operation lifetime plus bounded protocol overhead, leaving ordinary Target observations, every
  sibling client, worker runtime, authorization deadline, replay capacity, topology, envelopes,
  retry, trust, and TLS effects unchanged. The terminal restore aggregate repeats the same three
  historical VS Code Percona PVC failures and Gateway-DNS write-authority readiness failure, exits
  1, and preserves operational credentials because exact terminal cleanup is unproved. No
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- Code-local closure for `TLS-TARGET-ONE-SHOT-EXCEEDS-DEFAULT-HTTP-DEADLINE-2026-09-03` gives the
  Target one-shot schedule one capacity owner. The existing 15-minute authorization lifetime and a
  30-second bounded admission/framing/response margin derive a 930-second response timeout; the
  existing 180-second Kubernetes worker deadline is now projected from that same owner and remains
  unchanged. Lifecycle Authority uses a distinct transport only for TLS worker operations,
  retained material rewrap, and federation custody. Ordinary Target material/source/trust/
  decommission observations and every sibling client retain the generic 10-second default. The
  exact old→new mapping is therefore `Target one-shot calls: 10,000,000 µs; observations:
  10,000,000 µs` to `Target one-shot calls: 930,000,000 µs; observations: 10,000,000 µs`;
  process topology, request and worker concurrency, resource/load envelopes, authorization and
  worker deadlines, replay capacity, policies, retry, trust, TLS effects, and operation results
  are unchanged. The focused relationship regression passes **1/1**, the complete primary suite
  passes **4797/4797**, and auxiliaries pass **27/34/36**. Canonical `prodbox dev check` passes
  with the repository-pinned formatter, full-tree HLint `No hints`, conformance, and warning-clean
  all-target compilation; documentation lint and `git diff --check` pass. The synchronized
  executable is exact at
  `sha256:8713ebc64c16195f18c498e94d8e2750e52afde08c0b1cd00998bb5199d119c1`. Rerun the same
  live `pre-1` unchanged to prove the response crosses this derived budget before diagnosing or
  changing either secondary cleanup failure. No qualification artifact or activation witness
  exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The unchanged live `pre-1` builds local runtime image
  `sha256:d62d3e2d1352921f70312797d864513959182bc255c64fd2485ebd9b64460217`, publishes registry
  manifest `sha256:c36567b9dbb1d79cc2987fa9a4d7dcbf771d9424c9f88978c122e2ffd368be0a`, and imports OCI
  manifest `sha256:ccb41763c42c3e8b8b53efe702a5ad9cfe62f2fabb10ce15b5c2f6f65c45bf84`; retention removes
  only the superseded prior image. It live-proves the inner Target response-budget correction: the
  failure moves outward from Authority's `home-agent/transport-failed` projection to the host's
  exact `TlsRetentionWorkflowAuthorityClientTransportFailed
  (AuthenticatedClientTransportFailed (ControlPlaneTransportFailed (HttpTimeout "response
  timeout")))`. The host's generic Lifecycle Authority transport still waits 30 seconds, but the
  Authority-side retain program can invoke four sequential Target one-shot operations, each with
  the already-derived 930-second response bound. Stable counterexample
  `TLS-AUTHORITY-WORKFLOW-EXCEEDS-HOST-HTTP-DEADLINE-2026-09-03` owns this next exact
  outer-caller/program-schedule mismatch. Give only the host TLS-workflow route a response budget
  derived from that closed four-operation program plus bounded non-Target protocol overhead; leave
  generic Authority calls, retained-material delivery, all inner budgets, topology, concurrency,
  envelopes, deadlines, replay, retry, trust, and TLS effects unchanged. The terminal restore
  aggregate repeats the same three historical VS Code Percona PVC failures and Gateway-DNS
  write-authority readiness failure, exits 1, and preserves operational credentials because exact
  terminal cleanup is unproved. No qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- Code-local closure for `TLS-AUTHORITY-WORKFLOW-EXCEEDS-HOST-HTTP-DEADLINE-2026-09-03` gives the
  closed host TLS workflow one capacity owner. Its longest retain arm performs at most four serial
  Target one-shot calls, four ordinary ten-second Authority/adapter calls, and 30 seconds of
  bounded host admission, authenticated framing, response encoding, and final socket-write
  overhead. The derived TLS-workflow response timeout is therefore `4 × 930,000,000 µs + 4 ×
  10,000,000 µs + 30,000,000 µs = 3,790,000,000 µs`. The local Authority client exposes a
  distinct authenticated transport for only that route, and the home chart workflow selects it.
  The exact old→new mapping is `host TLS-workflow call: 30,000,000 µs` to `host TLS-workflow call:
  3,790,000,000 µs`; generic Authority calls remain `30,000,000 µs`, retained-material delivery
  remains `330,000,000 µs`, and all inner budgets, topology, concurrency, resource/load envelopes,
  authorization and worker deadlines, replay capacity, policies, retry, trust, TLS effects, and
  operation results are unchanged. The focused relationship regression passes **1/1**, the
  complete primary suite passes **4798/4798**, and auxiliaries pass **27/34/36**. Canonical
  `prodbox dev check` passes with the repository-pinned formatter, full-tree HLint `No hints`,
  conformance, generated-artifact checks, and warning-clean all-target compilation. Documentation
  lint and `git diff --check` pass. The synchronized executable is exact at
  `sha256:3fbc41a6cc81b8fde750afb0a3975540f7f229ab9f66a359a92aec0f66f800d8`. Rerun the same live
  `pre-1` unchanged to prove the host observes the workflow response before diagnosing or changing
  either secondary cleanup failure. No qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- The unchanged live `pre-1` builds local runtime image
  `sha256:0ead9a00cd94a6e276a9a5d230f9cbe563ffa15fd3b1ab9c94752d05a7947a3a`, publishes registry
  manifest `sha256:3fb2dbab244369b578189da349e1a43f5bbc09cddc6413c9126d0a70af27c3cd`, and imports OCI
  manifest `sha256:964d0e978eeaa326088ef935c2096f9c334b1972e673dd20b611652b986af78c` in 93.2 seconds;
  retention removes only the superseded `d62d3e2d…` image. It live-proves the host TLS-workflow
  response-budget correction: the request returns the next typed Authority result instead of
  `HttpTimeout`, namely `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`. Stable
  counterexample `TLS-AUTHORITY-SELECTED-AGENT-UNAVAILABLE-2026-09-03` owns this exact next closed
  boundary. Diagnose its retained selected-Agent observation and correct only the proven cause; do
  not change either secondary cleanup failure first. The terminal restore aggregate repeats only
  the same historical VS Code delete/reconcile failures over claims `prodbox-vscode-pg-instance1-
  2drb-pgdata`, `prodbox-vscode-pg-instance1-g7rp-pgdata`, and `prodbox-vscode-pg-instance1-rzmk-
  pgdata`, plus Gateway-DNS write-authority readiness; it exits 1 and preserves operational
  credentials because exact terminal cleanup is unproved. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- Code-local diagnostic closure for `TLS-AUTHORITY-SELECTED-AGENT-UNAVAILABLE-2026-09-03`
  preserves the refusal and exposes only its already-closed attach category. Production constructs
  exactly three attach failures—transport unavailable, invalid cleanup acknowledgement, or
  inconsistent terminal status—but the protected Target coordinator previously collapsed every
  one to `coordinator/attach-failed`. It now renders those cases as
  `attach-failed/transport-unavailable`, `attach-failed/cleanup-ack-invalid`, or
  `attach-failed/terminal-status-inconsistent`; arbitrary injected detail collapses to
  `attach-failed/other` and no subprocess text, byte, count, exit integer, or secret crosses the
  diagnostic boundary. The exact old→new mapping is therefore `target-one-shot/<schema>
  failure=coordinator/attach-failed` to that same prefix plus one closed value-free subcause.
  Process topology, request/worker concurrency, all budgets and deadlines, resource/load
  envelopes, replay capacity, policy, retry, trust, TLS effects, HTTP response, and cleanup are
  unchanged. The focused diagnostic regression passes **1/1**, the complete primary suite passes
  **4799/4799**, and auxiliaries pass **27/34/36**. Canonical `prodbox dev check` passes with
  repository-pinned Fourmolu, full-tree HLint `No hints`, conformance, generated-artifact checks,
  and warning-clean all-target compilation; documentation lint and `git diff --check` pass. The
  synchronized executable is exact at
  `sha256:83b6f931a8ad7f96a310cd04c2b92995e99de6e8411a67a6e46c0e953326245d`. Rerun live `pre-1`
  unchanged to select the exact attach subcause before changing behavior. No qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
- The diagnostic-only live `pre-1` builds local runtime image
  `sha256:725cfd3dd398deca36b6711cff6698d547c484bfd18e8da1e1b208e8bc32b8a7` in 1,218.2 seconds,
  publishes registry manifest `sha256:f5c13c2fac2d9fcb99816696eb2fe3465a23dce70624e4d93b32f960da12280f`, and imports OCI
  manifest `sha256:5634d4ba2a8de94c0b68164a852d6cc6e93498e85f47ec2c7cc87fb25074b9d4` in 96.4 seconds;
  retention removes only the superseded `0ead9a00…` image. The same host response is now refined
  by the protected Target log to exact `target-one-shot/tls-retain failure=coordinator/
  attach-failed/terminal-status-inconsistent`; Authority retains the outer
  `selected-agent/http-status/other` classification. Stable counterexample
  `TLS-RETAIN-TERMINAL-STATUS-INCONSISTENT-2026-09-03` owns this exact
  provisional-outcome/process-exit mismatch. Diagnose the closed worker outcome and exit mapping,
  then correct only the proven inconsistency; do not change either secondary cleanup failure
  first. The command process is no longer active, but its final PTY buffer did not survive the
  session rollover, so this diagnostic run makes no terminal aggregate-cleanup claim beyond the
  already captured three-claim Percona restore refusal. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- Code-local closure for `TLS-RETAIN-TERMINAL-STATUS-INCONSISTENT-2026-09-03` separates the
  authenticated worker domain result from the local attach transport result. The old mapping
  required provisional success plus `kubectl` `ExitSuccess`, or provisional refusal plus
  `ExitFailure`; the corrected mapping accepts either exact decoded provisional outcome only with
  `kubectl` `ExitSuccess`, because that exit reports completion of the local attach stream rather
  than the remote container's domain disposition. `ExitFailure` refuses either outcome. A
  controller decision refusal is likewise preserved only after the exact cleanup acknowledgement
  and successful attach-stream completion; the cleanup frame remains mandatory, and no process
  exit can manufacture a provisional outcome. Worker protocol, authentication, cleanup
  authorization, exact Job/Pod/SA cleanup, policy, retry, deadlines, resources, and TLS effects are
  unchanged. The focused regression passes **1/1**, the complete primary suite passes
  **4800/4800**, and auxiliaries pass **27/34/36**. Canonical `prodbox dev check` passes with
  repository-pinned Fourmolu, HLint `No hints`, conformance, generated-artifact checks, and
  warning-clean all-target compilation. The synchronized executable is exact at
  `sha256:dc309d8b9797acdc74b1cb50e90f150f9358f8f6747e590c3d59ccbdcbb901b3`. Rerun live
  `pre-1` unchanged; no qualification artifact or activation witness exists, no preactivation
  cycle has passed, and the legacy public writer remains sole.
- The corrected live `pre-1` builds local runtime image
  `sha256:16e34d563cb34626f17631b43130c61e85bf7fdf480ba81a4383fb1d4c9ce479` in 1,165.6 seconds,
  publishes registry manifest
  `sha256:fa9257b236c251f64aaafb13bd6cd3c718724d77bcf44580a07ed1c4a7056c72`, and imports OCI
  manifest `sha256:461f6d603582e61cb2729aa7ec999f953b1402771b18a2902bd8193fd93eba05` in 98.7 seconds;
  retention removes only the superseded `725cfd3d…` image. It crosses the former terminal-status
  inconsistency, completes the retained-home/runbook reconciles through a Ready ZeroSSL issuer,
  and then retains the same outer `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`. The
  protected Target log now identifies exact `target-one-shot/tls-retain failure=coordinator/
  materialization-refused`; Authority retains `selected-agent/http-status/other`. Stable
  counterexample `TLS-RETAIN-WORKER-MATERIALIZATION-REFUSED-2026-09-03` owns this worker-domain
  refusal. Add one closed value-free worker failure diagnostic before changing the TLS retain
  effect, Vault session, source material, policy, or retry behavior. The command exits 1 after the
  total restore graph reports exact failures only for VS Code delete/reconcile and public-edge wait:
  the same three stale Percona claims (`…-2drb`, `…-g7rp`, `…-rzmk`) prevent its expected claim set,
  and Gateway-DNS write authority is not ready. Websocket, API, and Gateway delete/reconcile plus
  Gateway MinIO bootstrap succeed. Exact terminal cleanup is not proved, so operational credentials
  are preserved. No qualification artifact or activation witness exists, no preactivation cycle
  has passed, and the legacy public writer remains sole.
- Code-local diagnostic closure for `TLS-RETAIN-WORKER-MATERIALIZATION-REFUSED-2026-09-03`
  preserves the authenticated provisional-refusal protocol and refines only its closed value-free
  detail. Existing non-TLS runtime failures retain `target-worker-materialization-refused`; TLS
  retain now distinguishes production-boundary unavailable, bad request, and every typed
  Target-agent cause without nested error values or size counts. The protected Target renderer
  admits only that exact vocabulary, keeps the established generic token unchanged, and collapses
  arbitrary injected text to `materialization-refused/other`. The old→new live mapping is therefore
  `coordinator/materialization-refused` to
  `coordinator/materialization-refused/tls-retain/<closed-cause>`. Worker effect, protocol,
  authentication, session cleanup, Target Job cleanup, retry, policy, resources, HTTP response,
  and TLS workflow behavior are unchanged. The focused regression passes **1/1**, the complete
  primary suite passes **4801/4801**, and auxiliaries pass **27/34/36**. Canonical `prodbox dev
  check` passes with repository-pinned Fourmolu, HLint `No hints`, conformance,
  generated-artifact checks, and warning-clean all-target compilation. The synchronized executable
  is exact at `sha256:25cfd9615f50350fb93a8f4a6bd51ab0c6a6787e1e90dd122506b6e4c5459ab2`.
  Rerun live `pre-1` unchanged to select the exact TLS-retain cause before changing behavior. No
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- The diagnostic live `pre-1` builds local runtime image
  `sha256:6e03748cd2f2e8b3c94e90dbee7a5e938dc188dd62f9972f7416facc3a0339c8` in 1,154.6 seconds,
  publishes registry manifest
  `sha256:dd4952435ac3435b8ea859dfe52ec9611fa6dd34090a013e3875dbb604593901`, and imports OCI
  manifest `sha256:7fc372f0f39caf887d74d38a71d18d8af84aeeeba57c71d0ca85f0e8b5544e0a` in 94.6 seconds;
  retention removes only the superseded `16e34d56…` image. The long-lived Target Agent's protected
  log selects exact `target-one-shot/tls-retain failure=coordinator/materialization-refused/
  tls-retain/secret-invalid`; Authority retains `selected-agent/http-status/other`. Stable
  counterexample `TLS-RETAIN-PUBLIC-EDGE-SECRET-INVALID-2026-09-03` owns this exact selected Target
  secret-shape refusal. Compare only the non-secret live Secret shape and certificate metadata with
  the closed parser contract before changing parsing, certificate issuance, source selection,
  policy, or retry. The command exits 1 with the unchanged three-claim VS Code restore and
  Gateway-DNS readiness failures; every other restore node succeeds and operational credentials
  remain preserved. No qualification artifact or activation witness exists, no preactivation
  cycle has passed, and the legacy public writer remains sole.
- Code-local closure for `TLS-RETAIN-PUBLIC-EDGE-SECRET-INVALID-2026-09-03` accepts cert-manager's
  canonical empty optional adoption-annotation values. Read-only live shape evidence proves exact
  type `kubernetes.io/tls`, exact data keys `tls.crt`/`tls.key`, present UID/resourceVersion, and a
  valid ZeroSSL certificate for `test.resolvefintech.com` through 2026-12-01; only
  `cert-manager.io/ip-sans`, `issuer-group`, and `uri-sans` have zero-length values. The parser
  previously applied its required-nonempty text validator to those optional values. It now permits
  empty values while retaining the control-character and 4,096-character bounds; annotation names
  remain cert-manager-prefixed, required-nonempty, and bounded, and every TLS
  type/data/certificate, source-identity, encoded-size, and cryptographic check is unchanged. The
  focused regression proves empty optional values accepted plus control and oversize values refused
  at **1/1**; the complete primary suite passes **4802/4802**, and auxiliaries pass **27/34/36**.
  Canonical `prodbox dev check` passes with repository-pinned Fourmolu, HLint `No hints`,
  conformance, generated-artifact checks, and warning-clean all-target compilation. The synchronized
  executable is exact at
  `sha256:41bbd1553ce79fa7cf2af430e945a3a760a477516c017696133a69be4eac9470`. Rerun live
  `pre-1` unchanged. No qualification artifact or activation witness exists, no preactivation cycle
  has passed, and the legacy public writer remains sole.
- The corrected live `pre-1` builds local runtime image
  `sha256:7fec010c40717f2cdfe071839309480694b4003d5fb5ca125a761f2b52f8ad2b` in 1,018.8 seconds,
  publishes registry manifest
  `sha256:4c04daca271b2d81f2505dea51a054fb9d3c75e98bfb9264b36386c152d62937`, and imports OCI
  manifest `sha256:adacbeec021d23f89364f0dd62e3f23532c4b93adfb88c6517c82c05a07c4562` in 95.8 seconds;
  retention removes only the superseded `6e03748c…` image. It crosses the exact TLS-retain secret
  parser barrier, completes both retained-home/runbook reconciles through a Ready ZeroSSL issuer,
  and advances into supported-runtime restoration. The next TLS verify transaction returns
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`; after terminal one-shot cleanup, the
  protected Target Agent log selects exact `target-one-shot/tls-verify failure=intent/unavailable/
  trust-install/client/response-codec/invalid/status/server/replay-capacity-exhausted`, while
  Authority retains `selected-agent/http-status/other`. Stable counterexample
  `TLS-VERIFY-TRUST-INSTALL-REPLAY-CAPACITY-EXHAUSTED-2026-09-03` owns this exact authenticated
  Target-intent replay-window refusal. Derive the complete Target Agent request envelope across the
  retained TLS workflow and the immediately unchanged attempt before changing the role-specific
  replay bound or encoded projection; do not clear non-empty replay state, weaken authentication,
  widen trust, or retry an unclassified refusal. The command exits 1 after the total restore graph
  repeats only the known VS Code delete/reconcile failure against claims `…-2drb`, `…-g7rp`, and
  `…-rzmk` plus Gateway-DNS write-authority readiness; all other restore nodes succeed. Exact
  terminal cleanup is not proved, so operational credentials remain preserved. No qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
- Code-local closure for `TLS-VERIFY-TRUST-INSTALL-REPLAY-CAPACITY-EXHAUSTED-2026-09-03` derives
  the complete finite Target Agent envelope instead of raising the old isolated credential bound
  by guesswork. One supported qualification attempt has five credential/source/delivery requests;
  TLS retain has four one-shot requests plus four Authority trust installations; restore has three
  plus three; and retain-on-ready has another four plus four. Capacity is therefore
  `2 * (5 + 8 + 6 + 8) = 54` for the complete attempt and its immediately unchanged retry inside
  the deadline-plus-skew horizon. Fifty-four accepted 2 MiB responses plus replay metadata fit the
  new 112 MiB encoded bound. The Vault listener now has an explicit finite 160 MiB request ceiling,
  which covers the projection's at-most 149.34 MiB Base64 expansion plus its bounded KV JSON
  envelope. The replay codec advances to v8 and admits canonical non-empty v2–v7 projections only
  when response-size/skew match and prior capacity does not exceed the new bound; it preserves
  every entry, while shrink, drift, corruption, and evidence clearing remain refused. TLS
  behavior, authentication, trust, request lifetime/skew, retry, and all other roles' replay bounds
  are unchanged. The focused primary regression passes **1/1**, the complete primary suite passes
  **4802/4802**, and auxiliaries pass **27/34/36**. The Vault chart renders the exact listener bound
  and Helm lint passes. Canonical `prodbox dev check` passes with repository-pinned Fourmolu, HLint
  `No hints`, conformance, generated/documentation policy, and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:793445b5ac2fcc2119266ef56fefbf787f314888adb3649a0d6f0babc0d8c9d1`. Rerun live
  `pre-1` unchanged. No qualification artifact or activation witness exists, no preactivation
  cycle has passed, and the legacy public writer remains sole.
- The pre-rerun deployment audit finds that closure incomplete at one chart-convergence edge:
  `helm upgrade --install` updates `vault-config`, but the Vault StatefulSet Pod template does not
  bind that ConfigMap identity. An existing Vault process can therefore keep its prior listener
  ceiling while `kubectl rollout status` reports the unchanged StatefulSet complete. The same
  `TLS-VERIFY-TRUST-INSTALL-REPLAY-CAPACITY-EXHAUSTED-2026-09-03` counterexample remains open; bind
  the rendered Vault configuration digest into the Pod template, prove unchanged renders stable
  and changed effective configuration rolls the StatefulSet, then repeat the local gates and live
  `pre-1`. No qualification state changes on source inspection alone.
- Code-local closure now binds `vault-config` to the Vault StatefulSet Pod template through Helm's
  SHA-256 of the rendered ConfigMap. Two identical root-mode renders produce exact digest
  `f18c40f0b4c7aa4f280a09990c9eaf65c70fcac76dcfd2583c49d65c8616a415`; changing the effective
  listener port produces distinct digest
  `75b77114435f962708ea4fe0872537f617e405888d43d7f42df2d9b27a645bac`, so unchanged reconcile is
  stable and any effective Vault configuration change rolls the process. Helm lint passes, the
  focused replay/config regression passes **1/1**, the complete primary suite passes
  **4802/4802**, and auxiliaries pass **27/34/36**. Canonical `prodbox dev check` passes with
  repository-pinned Fourmolu, HLint `No hints`, conformance, generated/documentation policy, and
  warning-clean all-target compilation. The synchronized executable remains exact at
  `sha256:793445b5ac2fcc2119266ef56fefbf787f314888adb3649a0d6f0babc0d8c9d1`. Rerun live `pre-1`
  unchanged to apply the listener ceiling and prove the same retained replay state migrates
  without clearing evidence. No qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- The unchanged live `pre-1` applies the Vault closure first: release revision 264 rolls from zero
  of one updated Pods to complete, StatefulSet generation 12 carries exact checksum
  `f18c40f0b4c7aa4f280a09990c9eaf65c70fcac76dcfd2583c49d65c8616a415`, current/update revision
  `vault-bb86fbfd9`, and replacement Pod UID `c0d04160-a42d-482c-ba15-b8f71e76a38d` is Ready with
  zero restarts and the live ConfigMap contains `max_request_size = 167772160`. It then builds
  local runtime image `sha256:c05eab187b217e05ddb493544420cce21178910d85e55ac9364a74f3ef6bd76b` in
  1,015.2 seconds, publishes registry manifest
  `sha256:4278da7a2ffd1c3b4a2cf997bedceb8cce8c01ed0b3ff718c0871caa68c3cc63`, and imports OCI
  manifest `sha256:43a01f39072deed70d74953deedf33df18688778c92b72e374c7e1708696fc99` in 98.5
  seconds while deleting only the superseded runtime image. Before candidate execution, the
  Lifecycle Authority Helm upgrade finds its pre-existing Pod in `CrashLoopBackOff` with 48
  restarts and fails revision 124 because zero of one replicas is Ready; the supported
  terminal-failure path uninstalls the release and proves the StatefulSet/Pod/release absent while
  its exact retained `authority-journal-lifecycle-authority-0` PVC remains Bound. Stable
  counterexample `LIFECYCLE-AUTHORITY-STARTUP-CRASHLOOP-2026-09-03` owns this new prerequisite
  barrier. The terminal cleanup removes the failed Pod before its startup diagnostic is retained
  in command output, so no behavior change is licensed: repeat the same supported command and
  capture only the exact value-free Lifecycle Authority startup log while the Pod exists. The
  Target replay migration has not yet executed, no qualification artifact or activation witness
  exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The unchanged diagnostic `pre-1` reuses local image
  `sha256:c05eab187b217e05ddb493544420cce21178910d85e55ac9364a74f3ef6bd76b`, registry manifest
  `sha256:4278da7a2ffd1c3b4a2cf997bedceb8cce8c01ed0b3ff718c0871caa68c3cc63`, and the current
  containerd import. It recreates Lifecycle Authority Pod UID
  `84f72796-81e5-49fb-a3f3-aafee6ef64db` on that manifest, proves Ready with zero restarts, and
  crosses the startup edge twice in the supported prerequisite/runbook sequence; this live-closes
  `LIFECYCLE-AUTHORITY-STARTUP-CRASHLOOP-2026-09-03` as a terminal rollout-transition failure
  recovered by the already-supported failed-release uninstall, exact absence read-back, and
  unchanged reconcile. The run also crosses
  `TLS-VERIFY-TRUST-INSTALL-REPLAY-CAPACITY-EXHAUSTED-2026-09-03` and enters Phase 1.6, proving the
  retained Target replay projection migrated to v8 without evidence clearing. The next restore
  transaction returns `TlsRetentionWorkflowAuthorityAdapterUnavailable`; after terminal one-shot
  absence, the Authority log selects exact `tls-retention/workflow failure=adapter-unavailable`,
  while the Target Agent and TLS Retention logs are empty. The TLS Retention deployment is Ready,
  zero-restart, exact-image, and backed by endpoint `10.42.0.79:8600`; both directional
  NetworkPolicy arms exactly admit Authority-to-adapter port 8600. Stable counterexample
  `TLS-RESTORE-AUTHORITY-ADAPTER-UNAVAILABLE-2026-09-03` owns the still-coarse client failure. Add
  a closed, payload-free diagnostic over every `TlsRetentionClientError`, including exact outer
  authenticated-role status classification, without changing the host response, request,
  adapter, retry, or storage behavior; rerun `pre-1` to select the exact arm. The aggregate then
  repeats only the known VS Code stale claims `…-2drb`, `…-g7rp`, `…-rzmk` and Gateway-DNS
  write-authority readiness; all other restore nodes succeed, exact terminal cleanup is not
  proved, and operational credentials remain preserved. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The licensed diagnostic boundary is now code-local closed. The TLS Retention client maps a failed
  store response and a non-decodable failed restore response through the shared total
  authenticated-role static-response classifier, retains only its closed observation, and renders
  every client error to a payload-free cause. Only the authored status/body pair renders
  `http-status/replay-capacity-exhausted`; arbitrary response bytes render `http-status/other` and
  do not survive the error. Decoded `404` missing and `500` corrupt observations retain their
  existing semantics; the workflow's public response and coarse terminal classification remain
  unchanged, while the value-free Authority log now nests the client cause below `adapter/`. The
  focused regression passes **1/1**, the complete primary suite passes **4803/4803**, and
  auxiliaries pass **27/34/36**. Canonical `prodbox dev check` passes with repository-pinned
  Fourmolu, HLint `No hints`, generated/documentation policy, and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:23b4f3bab1e782f89ab4a72ae4f9b3f258e74842f870405d34e4d760e01debd1`. Repeat live
  `pre-1` unchanged to select the exact cause. No qualification artifact or activation witness
  exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The diagnostic live `pre-1` builds local image
  `sha256:2b96e1745697c2e12b6cc79d740ccabaf288564522a2ddbd08edce5a0fc3ec2c` in 1,147.7
  seconds, publishes registry manifest
  `sha256:2d3054360a96a8741d03122fc6c53bfddeaf77d3299f5a4da709d9d015bbb1c6`, and imports
  OCI manifest `sha256:d8989c80dd765cc12f0ed6e4ec046ab80e7d3d9050594d570a378935a9f27de2` in
  98.6 seconds while deleting only the superseded `sha256:c05eab187b...` image. The supported
  prerequisite and runbook passes reuse those exact identities, cross the control-plane and
  platform rollouts, and enter Phase 1.6. Restore again returns the deliberately unchanged public
  result `TlsRetentionWorkflowAuthorityAdapterUnavailable`, but the new Authority diagnostic
  selects exact `tls-retention/workflow failure=adapter/http-status/other`, disproving the
  replay-capacity hypothesis. After the terminal aggregate, the Target, Authority, and TLS
  Retention namespaces each contain only their long-lived zero-restart Pod (UIDs
  `989acc87-495a-483e-85b6-36998929fcea`, `9c0d82bf-b3dc-4c91-a0b2-738ff77c03f8`, and
  `252595e7-a461-4bba-b564-ed1aee24f195` respectively); the Target log is empty. The same three VS
  Code claims and Gateway-DNS write-authority readiness remain the only aggregate companions,
  exact terminal cleanup is not proved, and operational credentials remain preserved. Stable
  counterexample `TLS-RESTORE-ADAPTER-HTTP-STATUS-OTHER-2026-09-03` owns the still-collapsed
  failed HTTP response: enumerate the finite server and TLS endpoint response producers that can
  reach this client, then add only a closed payload-free distinction if source evidence leaves
  more than one candidate. No qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- Source enumeration now closes that diagnostic boundary code-locally without changing the wire.
  The TLS endpoint owns one total plaintext-response projection over repository failure, the four
  closed request-codec refusals on each route, invalid store envelope, store digest mismatch, and
  restore read failure; the existing authenticated-role projection remains the separate outer
  producer. The client matches exact status/body pairs from those two producers, discards arbitrary
  bytes and the raw numeric status, and renders endpoint causes below `http-status/store/...` or
  `http-status/restore/...`; every unmatched server response remains `http-status/other`.
  Successful store/restore responses and decoded `404` missing / `500` corrupt observations retain
  their canonical-CBOR semantics, and request, replay, retry, repository, public response, and
  workflow behavior are unchanged. The warning-clean unit target builds and the focused exhaustive
  regression passes **1/1**; the complete primary suite passes **4803/4803**, and auxiliaries pass
  **27/34/36**. Canonical `prodbox dev check` passes with repository-pinned Fourmolu, HLint `No
  hints`, generated/documentation policy, and warning-clean all-target compilation. The
  synchronized executable is exact at
  `sha256:a3dbc8b11a8df478384a8702f09bca7712d2dfdc871e3a565a13d2a1ce6b89c4`.
  Unchanged live `pre-1` is next. No qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- The unchanged diagnostic `pre-1` builds local image
  `sha256:3dac3492463a402e3015042c34cbc21cb5ad5fb3ab5a5e8a1c46efb3f08e22f1` in
  1,141.4 seconds, publishes registry manifest
  `sha256:2eacce935e832d69567637b728a500c72e80c078cee57f9f76ff4bc4b296b1b8`, and
  imports OCI manifest `sha256:5e69beababcb2a65703b630b7e6b73739e8f405510d946deacc209c93361751a`
  in 96.4 seconds while deleting only the superseded local image and registry manifest. The
  prerequisite and runbook passes reuse those exact identities, cross the control-plane/platform
  rollouts, and enter Phase 1.6. The public result remains
  `TlsRetentionWorkflowAuthorityAdapterUnavailable`, while the exact Authority diagnostic selects
  `tls-retention/workflow failure=adapter/http-status/store/repository-failed`, live-closing the
  collapsed-HTTP counterexample and proving the failure occurs inside the Adapter's immutable store
  repository rather than replay, request decoding, or restore. Post-terminal read-back finds only
  the Ready, zero-restart exact-image Target Agent, Lifecycle Authority, and TLS Retention Pods
  (UIDs `e8fc2edf-3a0f-478e-9c90-65547e54c30c`,
  `7c4f0de5-3523-4ff3-9aae-9221a7b86401`, and
  `d3530f67-b252-45b9-8df1-7d55b01b5fb3`) and no one-shot Jobs in those namespaces. The same three
  VS Code claims and Gateway-DNS readiness remain the only aggregate companions; exact terminal
  cleanup is not proved and operational credentials remain preserved. Stable counterexample
  `TLS-STORE-REPOSITORY-FAILED-2026-09-04` owns the remaining collapsed repository failure. Add a
  closed, value-free diagnostic across credential loading, immutable PUT, and confirmation
  read-back before changing S3 requests, permissions, retry, object naming, or storage behavior.
  That diagnostic is now landed without changing those storage semantics: eager TLS Adapter
  binding classifies credential read and required-field failures through one role-local
  payload-free startup vocabulary, while the repository response carries the exact immutable-PUT
  disposition (`unobservable`, `applied`, or `conflict`) crossed with the exact confirmation
  failure (unobservable, missing, byte mismatch, invalid envelope, envelope mismatch, or digest
  mismatch). Transport bodies, paths, fields, object bytes, and decoder details cannot enter the
  endpoint or Authority token. Focused endpoint/adapter **21/21**, protected-startup **15/15**,
  primary **4806/4806**, and auxiliaries **27/34/36** pass. Canonical `prodbox dev check` passes
  with the repository-pinned formatter, HLint (`No hints`), generated/documentation policy, and
  warning-clean all-target compilation; the synchronized executable is exact at
  `sha256:c3a44376bb84a4f6f389f84189aea1add3a0c407ae7356a6c1bb353de65f73f4`. Unchanged live
  `pre-1` is next. No qualification artifact or activation witness exists, no preactivation cycle
  has passed, and the legacy public writer remains sole.
  The unchanged diagnostic `pre-1` builds local image
  `sha256:77635d7c0146aff13f1d0be7f7bb4945984b2c5e66d2177234f67902d2aa5b0e` in
  1,153.2 seconds, publishes registry manifest
  `sha256:8bec822dbb5ce8a21a1adf9b7c4c7fee469a9da10c950ec4db745e4fffbb6540`, and imports
  OCI manifest `sha256:74b27fded376e523152336594f6b7700b639d3efa566dc4e648ebd078a87517d`
  in 98.3 seconds while deleting only the superseded local image and registry manifest.
  Prerequisite and runbook passes reuse those exact identities and cross the
  platform/control-plane rollouts. The public result remains
  `TlsRetentionWorkflowAuthorityAdapterUnavailable`; the exact Authority token is now
  `tls-retention/workflow failure=adapter/http-status/store/repository-failed/put/conflict/confirmation/bytes-mismatch`.
  This proves the immutable object version already exists and its authoritative read-back differs
  from the candidate bytes; credential loading, PUT unobservability, missing read-back, and
  transport failure are excluded. Post-terminal read-back finds no one-shot Jobs in the Target
  Agent, Lifecycle Authority, or TLS Retention namespaces and finds their exact-image Pods Ready
  with zero restarts (UIDs `0909ef08-19d6-4120-a58e-33453d3f1f7e`,
  `9330920d-cf5f-4317-84c1-b5f29b530b74`, and `b1e40171-0284-43ea-a988-4de4c4f4847a`).
  The same three stale VS Code claims and Gateway-DNS readiness remain the aggregate companions;
  exact terminal cleanup is not proved and operational credentials remain preserved. Stable
  counterexample `TLS-RETENTION-IMMUTABLE-VERSION-CONFLICT-BYTES-MISMATCH-2026-09-04` owns the
  collision. Prove whether the retained Authority pending/current reference reused or reassigned
  the version and whether the conflicting object belongs to that exact candidate before changing
  version allocation, object naming, replay, deletion, or overwrite behavior. No qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
  Source inspection proves the mechanism: the durable state is only `TlsRetentionEmpty` or
  `TlsRetentionCurrent`; the workflow derives `current + 1`, asks the Target Agent for randomized
  ciphertext, and reaches `versions/<n>.envelope` before any pending-intent CAS exists. A prior
  post-PUT interruption can therefore leave the exact next immutable key occupied while the
  retained state still allocates that version, and retry necessarily supplies different bytes.
  Close it with the doctrine's missing durable pending outbox: stage the exact reference, opaque
  envelope, and approval before PUT; resume that byte-identical candidate after interruption; and,
  for the existing pre-outbox orphan, observe the exact allocated version and adopt it only after
  its envelope decrypts under the candidate's version/certificate/source AAD and the selected Agent
  proves exact idempotent apply/read-back. Corrupt, changed-source, or unobservable legacy
  occupation must refuse. This recovery neither overwrites nor deletes an immutable object and does
  not scan or select S3 `latest`.
  The code-local durable-outbox closure is now landed. The retained TLS aggregate appends
  `TlsRetentionPendingState` without shifting the two existing canonical-CBOR constructors and
  stores the exact predecessor, approval, reference, and bounded opaque envelope before any
  Adapter PUT. Exact pending replays reuse those bytes and stored approval; divergent pending
  intent, unstaged promotion, semantically invalid durable state, invalid reference fields,
  digest/version mismatch, validity regression, and unapproved key rotation all refuse before
  mutation. Authority stage and Adapter exact-version-observe routes are appended to the
  authenticated route/code registries, with prior route codes and prior Authority-response CBOR
  tags preserved. The normal missing-version path stages before immutable storage; a pending retry
  performs no fresh Target encryption; and the bounded pre-outbox recovery performs one exact-
  version GET, adopts only after the stored envelope decrypts under candidate
  version/certificate/source AAD and the selected Agent proves an idempotent exact-content
  read-back, then stages, confirms the existing bytes, re-observes the exact source, and promotes.
  Missing source, corrupt/unobservable bytes, changed AAD/source, or non-idempotent Agent read-back
  refuse; there is no overwrite, delete, list, or `latest` surface.
  The legacy adoption branch adds exactly two Target-Agent transactions to the prior complete
  qualification-attempt envelope (selected prepare + home rewrap + selected restore replace the
  ordinary home wrap). The derived per-attempt maximum is therefore **29**, retained replay
  capacity is **58** for that complete attempt and its immediately unchanged retry, and the
  encoded ceiling is **118 MiB** for 58 maximum-size responses plus metadata. Its at-most 157.34
  MiB Base64 expansion plus the bounded KV JSON envelope remains contained by the already-rendered
  finite 160 MiB Vault listener request ceiling; no authentication lifetime, skew, or other role
  bound changes. Because the deployed Target replay projection is already canonical v8 at capacity
  54, this widening advances the codec to **v9** and admits canonical v2–v8 projections only when
  response-size/skew match and prior capacity does not exceed 58. Every retained entry survives the
  migration; capacity shrink, limit drift, corruption, or evidence clearing still refuses. The
  state codec rejects
  oversized or semantically forged current/pending values while preserving the exact legacy
  Empty/Current encodings; byte-compat regressions also pin all pre-stage Authority response tags
  and the pre-move immutable-envelope encoding. The warning-as-error all-target build passes; the
  TLS Authority fold passes **21/21**, the Adapter/workflow endpoint group passes **25/25**, the
  refreshed primary suite passes **4823/4823**, and auxiliaries pass **27/35/36**. The workflow
  group directly proves corrupt occupation, unobservable exact-version observation, missing source,
  and non-idempotent Agent read-back all refuse before Authority staging.
  Canonical `prodbox dev check` exits 0 with repository policy, pinned formatting, HLint (`No
  hints`), documentation/generated-artifact checks, and warning-clean all-target compilation;
  `git diff --check` also passes. The gate-built executable and synchronized `.build/prodbox` are
  byte-identical at
  `sha256:ec0c2a14f08661e8c217a571c3728acbdfc33f250afcf163ffbf62f8d9e55e4c`. Live `pre-1`
  remains to be completed on this revision. Therefore
  `TLS-RETENTION-IMMUTABLE-VERSION-CONFLICT-BYTES-MISMATCH-2026-09-04` remains registered: no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
  The corrected live `pre-1` candidate builds local runtime image
  `sha256:ce38381469f33164439ff3f4f88b8f20677bb1046139e921c1093d5f4f9211f4` in 1,148.0
  seconds, publishes registry manifest
  `sha256:b0c70934432986277c73e25b05da694adc3a5346303469efef16edd9823969fd`, imports OCI
  manifest `sha256:553ba7f68b8b2b3eec51296f1085677c599ff87e816ba395dd6059b8d8c5caca` in
  107.2 seconds, and removes only the superseded local image/manifest. Both prerequisite/runbook
  passes cross TLS Retention without the immutable-version collision, and the destructive restore
  positively reports that the public-edge certificate was retained through the Authority and TLS
  Retention Adapter. After Gateway namespace recreation, `RestoreChartVscode` nevertheless fails
  with the exact public diagnostic `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`; the
  total restore executor still attempts API and WebSocket, while public-edge readiness separately
  reports the already-known Gateway-DNS write-authority refusal. Exact terminal cleanup is not
  proved, so operational credentials are preserved. Stable counterexample
  `TLS-RETENTION-RESTORE-SELECTED-AGENT-UNAVAILABLE-2026-09-04` owns this next boundary before any
  client, authentication, replay, trust, timeout, or restore behavior changes. No qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
  The licensed behavior-neutral discriminator is now code-local complete. The one-shot Target
  worker preserves a TLS-restore production-boundary refusal or the exact closed
  `TlsTargetAgentError` constructor through its authenticated provisional completion instead of
  collapsing both to the generic materialization refusal. Rendering maps all nine Target error
  arms to finite value-free `tls-restore/*` tokens; parameterized DEK, cipher, and ciphertext-size
  values cannot reach the token. The standing Target Agent admits only that explicit token set
  (plus the existing TLS-retain set), while arbitrary worker detail still collapses to
  `materialization-refused/other`. Restore execution, request/response transport, authentication,
  replay, trust, timeout, and Secret comparison/apply behavior are unchanged. The focused
  exhaustive diagnostic regression passes **1/1**, the warning-as-error all-target build passes,
  and the full primary suite remains **4823/4823**. Repository policy, pinned formatting, HLint
  (`No hints`), documentation/generated-artifact checks, and warning-clean all-target compilation
  pass through canonical `prodbox dev check`; the gate-built executable and `.build/prodbox` are
  byte-identical at
  `sha256:dab7bd25283ae4bb55b9d3146c8fa65337a285536d954db5eab0c3fe03c643b6`. Rerun the exact
  live `pre-1` operation unchanged and inspect only the closed standing Target-Agent/Authority
  diagnostic tokens to select the proven restore cause before changing behavior. The
  counterexample and all qualification/activation/legacy-writer status remain unchanged until
  that live evidence.
  The unchanged diagnostic `pre-1` live run builds local image
  `sha256:cc9795386f9e629249f0d5c2a8019b9230c31fd5c48e688453c55452eeb7a7a7` in 1,152.3
  seconds, publishes registry manifest
  `sha256:05474538d1b196faced00cc6d8f60af31b339c8cab0268cbe184c6df0cf2e137`, and imports OCI
  manifest `sha256:608b706047db71983f56799cf66c3add5ebd67b0220dd873624c61b9bfec5758` in 101.6
  seconds. It removes only the immediately superseded local image and registry manifest. Both
  prerequisite/runbook passes cross TLS Retention and all retained roles on the exact candidate.
  Because the prior failed restore left no public-edge Secret or Certificate, the destructive
  delete has no new source to retain; after Gateway recreation the retained restore nevertheless
  reaches the selected Agent and again surfaces public
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`. The new closed standing Target-Agent
  diagnostic is exactly
  `coordinator/materialization-refused/tls-restore/secret-apply-failed`; the Authority diagnostic
  remains the expected `selected-agent/http-status/other`. This live-proves decrypt, ciphertext
  decode, retained-reference equality, and entry into exact Secret apply, while ruling out DEK,
  cipher, ciphertext, reference, and read-back arms. API and WebSocket continue through the total
  executor; public-edge readiness separately retains the already-known Gateway-DNS write-authority
  failure. Exact terminal cleanup is not proved, so operational credentials are preserved.
  Register stable counterexample `TLS-RETENTION-RESTORE-SECRET-APPLY-FAILED-2026-09-04` before
  changing Secret apply, restore, or namespace lifecycle behavior. No qualification artifact or
  activation witness exists, no preactivation cycle has passed, and the legacy public writer
  remains sole.
  The licensed apply discriminator is now code-local complete without changing restore semantics.
  `K8sSecretApplyError` classifies request construction, transport, the finite relevant HTTP status
  classes, 5xx, and unexpected status once at the in-cluster HTTP boundary; API bodies, integer
  statuses, and exception text are discarded there. `TlsSecretApplyFailure` separately names
  initial observation failure, corrupt/different existing content, every closed apply-request
  class, and unavailable/missing/corrupt/different post-apply read-back. The Target error and
  authenticated worker refusal carry only that closed constructor, and the standing Agent derives
  its exact allowlist from the complete bounded enumeration; arbitrary text still maps to `other`.
  Exact Secret GET, non-forcing server-side apply, content comparison, RBAC, and restore control
  flow are unchanged. Read-only authorization observation confirms the one-shot ServiceAccount can
  `get` and `patch` exact `secret/public-edge-tls` but cannot namespace-wide `create`, matching the
  intended exact-name capability. Three focused regressions pass **1/1** each, the full primary
  suite passes **4824/4824**, the warning-as-error all-target build passes, and canonical `prodbox
  dev check` passes with repository policy, pinned formatting, HLint (`No hints`),
  documentation/generated artifacts, and warning-clean compilation. The gate-built executable and
  `.build/prodbox` are byte-identical at
  `sha256:5b3762e2193993254552df5bd19be4f498dba9471361d8f7711640cb4d491a1f`. Rerun live `pre-1`
  unchanged and inspect only the closed standing Target-Agent/Authority tokens to select the exact
  apply subcause before changing behavior. The stable counterexample and all
  qualification/activation/legacy-writer status remain unchanged until that live proof.
  The exact unchanged `pre-1` rerun builds local image
  `sha256:95d95b361f53262596d5fc9f0be3c2e7856fbe550a1e72eadfcd30ca140eb0ca` in 1,144.7
  seconds, publishes registry manifest
  `sha256:f694a95b264da33c2537d6152995027984e157fe0beb35f0727b2cf0e90b79fd`, and imports OCI
  manifest `sha256:3f7ee036d8750d7476179c543d6053a9264c7c4ac1ae679e957b532c0f14098c` in 93.4
  seconds. It removes only the immediately superseded local image and registry manifest, and both
  prerequisite/runbook passes cross TLS Retention and every retained role on the exact candidate.
  The public-edge Secret and Certificate remain absent before deletion; after Gateway recreation
  the retained restore again surfaces public
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`. The only licensed standing diagnostics
  are now exact Target-Agent
  `coordinator/materialization-refused/tls-restore/secret-apply-failed/http-forbidden` and Authority
  `selected-agent/http-status/other`. Together with the read-only authorization observation that
  the one-shot ServiceAccount can patch exact `secret/public-edge-tls`, cannot create Secrets, and
  the Secret is absent, this live-proves that the non-forcing absent-object server-side apply is
  rejected with HTTP 403 before post-apply read-back. Register stable successor counterexample
  `TLS-RETENTION-RESTORE-SECRET-APPLY-HTTP-FORBIDDEN-2026-09-04` before changing namespace
  lifecycle, Secret establishment, apply behavior, or capability scope. API and WebSocket complete
  through the total executor; VS Code fails only at retained TLS restore, while public-edge
  readiness separately retains the known Gateway-DNS write-authority failure. Exact terminal
  cleanup is not proved, so operational credentials remain preserved. No qualification artifact
  or activation witness exists, no preactivation cycle has passed, and the legacy public writer
  remains sole.
- The registered
  `TLS-RETENTION-RESTORE-SECRET-APPLY-HTTP-FORBIDDEN-2026-09-04` counterexample is now closed
  code-locally by an exact graph-owned restore slot rather than by widening the Target worker's
  capability. After namespace and exact access reconciliation and before the Authority restore,
  the chart graph performs one `kubectl create` of `vscode/public-edge-tls` as a marked,
  non-secret-bearing `kubernetes.io/tls` object whose required `tls.crt` and `tls.key` values are
  empty. Only command success or an API-server `AlreadyExists` refusal found in stderr is accepted;
  the host does not read the Secret. The selected one-shot ServiceAccount remains limited to
  exact-name `get` and `patch`, accepts only that complete still-empty slot shape, carries its
  observed opaque Kubernetes `resourceVersion` into an exact-name JSON merge PATCH as an optimistic
  CAS, and independently reads back the restored content. Missing, corrupt, different, immutable,
  or unobservable slots, a concurrent replacement, every closed HTTP failure, and an unchanged slot
  after patch all fail closed through the bounded worker diagnostic vocabulary. The
  warning-as-error all-target build passes, focused restore-slot behavior passes **4/4**, strict
  `AlreadyExists` classification passes **1/1**, the closed diagnostic vocabulary passes **1/1**,
  and the full primary suite passes **4828/4828** in 90.97 seconds. The governed global inventory,
  lifecycle, ChartPlatform, and public-edge doctrines agree with that boundary; documentation and
  diff checks pass. Canonical `prodbox dev check` exits 0 with repository policy, pinned formatting,
  HLint (`No hints`), generated artifacts/documentation, and warning-clean all-target compilation.
  The gate-built executable and `.build/prodbox` are byte-identical at
  `sha256:eca40a9a82448295b6cdb0a865dd63e7eef562f36dccde5bbc01767ef589648b`. The next action
  is the exact unchanged live `pre-1` rerun. Deployment qualification remains `pending`: no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- The exact unchanged live `pre-1` rerun builds local image
  `sha256:07638eb36a2976ea14d61c5f4c82181e220baf647da2471c68f9b3bd0d7d010f` in 1,137.5
  seconds, publishes registry manifest
  `sha256:ebe3f4fe32be0c4635b0b32abd3fe1db7c976ae122f344465a2b45f658c4ae03`, and imports OCI
  manifest `sha256:63dda611a2bb0e8f897e7b67b303f70c9eace5a68b74b2fc274d8d9a5ef640d3` in 85.6
  seconds. It removes only the immediately superseded registry manifest
  `sha256:f694a95b264da33c2537d6152995027984e157fe0beb35f0727b2cf0e90b79fd` and local image
  `sha256:95d95b361f53262596d5fc9f0be3c2e7856fbe550a1e72eadfcd30ca140eb0ca`. The retained
  runbook passes cross Bootstrap Broker, Target Agent, Lifecycle Authority, Authority Backup,
  Provider Worker, Gateway, TLS Retention, and the shared platform barriers on the exact candidate.
  The total restore executor proves all four chart deletions, Gateway/API/WebSocket reconstruction,
  and storage preservation; VS Code alone fails with public
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`, while public-edge readiness separately
  retains the known Gateway-DNS write-authority failure. The only licensed standing diagnostics are
  Target-Agent `target-one-shot/tls-prepare failure=coordinator/attach-failed/transport-unavailable`
  and Authority `tls-retention/workflow failure=selected-agent/http-status/other`. This run therefore
  does not reach exact Secret apply and cannot live-close the restore-slot correction. Register
  stable successor counterexample
  `TLS-RETENTION-PREPARE-ATTACH-TRANSPORT-UNAVAILABLE-2026-09-04` before changing Target-worker
  creation, attachment, transport, deadlines, cleanup, or TLS prepare behavior. Exact terminal
  cleanup is not proved, so operational credentials remain preserved. No qualification artifact or
  activation witness exists, no preactivation cycle has passed, and the legacy public writer
  remains sole. Resume by diagnosing the exact bounded one-shot attach path from source and
  non-secret Kubernetes object/status observations, without widening the licensed log surface.
- That diagnosis is now source- and status-local. Read-only events show the exact TLS-prepare Pod
  was scheduled, pulled, created, and started at 08:24:07--08 EDT, while the standing Target Agent
  recorded the attach refusal at 08:24:16 EDT; the ten-minute exchange wall clock therefore did not
  fire, and no worker object remains. The bounded exchange currently collapses limits validation,
  initial-frame bounds, process start, initial write, provisional read, continuation write,
  completion collection, and wall-clock timeout into the same `transport-unavailable` token. A
  worker that exits before its first provisional frame is indistinguishable from a failed
  `kubectl attach`. The next correction is behavior-neutral: carry only that closed transport stage
  to a value-free Target-Agent token, retain the existing secret/payload erasure and exact cleanup,
  validate locally, then rerun the same `pre-1` counterexample before changing transport behavior.
- That behavior-neutral diagnostic is now closed code-locally. The generic bounded framed exchange
  retains an exhaustive eight-constructor transport stage for limits validation, initial-payload
  validation, process start, initial-payload write, provisional read, decision-continuation write,
  completion collection, and wall-clock timeout. The Target boundary projects those constructors
  to eight fixed value-free details and then to eight closed `attach-failed/...` tokens; the
  underlying exception, `kubectl` response, payload, and frame bytes remain erased, and no
  deadline, retry, attachment, cleanup, or TLS-prepare behavior changes. The exact vocabulary
  regression passes **1/1**, a real child that consumes its initial frame and exits before a
  provisional frame is classified at `provisional-read` in **1/1**, warning-as-error all-target
  compilation passes, and the canonical unit command passes the complete **4829/4829** primary
  cases plus authenticated control-plane auxiliaries **35/35** and **36/36**. Governed
  documentation, documentation lint, and diff checks pass; canonical `prodbox dev check` exits 0
  with repository policy, pinned Fourmolu, HLint (`No hints`), generated
  artifacts/documentation, and warning-clean all-target compilation. The gate-built executable and
  `.build/prodbox` are byte-identical at
  `sha256:225ceb56b4877ff4b8836da10bff7741cf5ae1c667f1ffd4bfdfbc3561f2f3c1`. Rerun the same
  live `pre-1` counterexample on this diagnostic-only revision and use its exact value-free stage
  before licensing any transport behavior change. Deployment qualification remains `pending`: no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- The diagnostic-only live `pre-1` rerun builds local runtime image
  `sha256:9d2a79b5b142f04271ee8a9477b24082d982d5f777e693e0368d477538eedb5a` in 1,165.1
  seconds, publishes registry manifest
  `sha256:e571c53f8e7b00453efbd76d5027d20adbb2170f187f921d246b48edc05ba230`, and imports OCI
  manifest `sha256:f1b7911b3ec419dac6d6de024c3f644931ee9d75c8a74a7ac5f0f3ffcd8ba8fa` in 87.4
  seconds. It removes only the prior registry manifest `sha256:ebe3f4fe...` and local image
  `sha256:07638eb3...`, then crosses the retained-home, platform, Provider, Gateway, TLS Retention,
  and runbook barriers on the exact candidate. The total restore executor again proves all four
  chart deletions plus Gateway, API, and WebSocket reconstruction. VS Code restoration stops first
  after its 1,800-second Patroni convergence budget with exact non-secret status
  `status=initializing,postgres.ready=2,expected.postgres.ready=3`; public-edge readiness separately
  retains the known Gateway-DNS write-authority refusal. Neither licensed standing log contains a
  new TLS operation: Target Agent emits nothing and Authority emits only the retained
  `aws-admin/prepare authority-phase=completed`, so the one-shot attach is not entered and
  `TLS-RETENTION-PREPARE-ATTACH-TRANSPORT-UNAVAILABLE-2026-09-04` remains not live-closed. Register
  the distinct stable counterexample
  `VSCODE-RESTORE-PATRONI-THREE-REPLICA-READINESS-TIMEOUT-2026-09-04` before changing Percona,
  storage, restore ordering, readiness budgets, or TLS behavior. Exact terminal cleanup is not
  proved, so operational credentials remain preserved. No qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
  Resume with exact non-secret Percona object/status, Pod/PVC/PV ownership, node placement, and
  event observations; do not widen the licensed log surface.
- That read-only diagnosis closes the ambiguity. Percona 2.9 publishes the selectorless primary
  Service and its Endpoints/EndpointSlice as a ready IP with no `targetRef`; the current
  endpoint-to-Pod observer therefore returns no anchor even though the exact `hh5k` Pod carries the
  closed `postgres-operator.crunchydata.com/role=primary` label and its `postgres-data` volume names
  the bound PVC. Full expansion consequently takes the no-anchor sorted fallback: its applied
  manifests assign retained PV0 to the new lexically first `5krm` claim, retained PV1 to
  already-bound `hh5k`, and retained PV2 to `rwr7`. The PV controller preserves PV0's actual
  `hh5k` binding, PV1 stays Available but prebound to that same claim, and `5krm` stays Pending; 122
  PVC `WaitForPodScheduled` observations and 16 Pod `FailedScheduling` events report no available
  PV. The source also validates but discards the ordinal-stripped Pod prefix when deriving a claim
  name. Close the registered counterexample by observing the exact single role-labelled primary
  Pod and its `postgres-data` PVC (rather than requiring an absent Endpoint target reference),
  deriving the ordinal-free claim name, and retaining that bound PV as the anchor while assigning
  only follower claims. Multiple, missing, malformed, unbound, or non-owned primary observations
  must retain the existing no-live-anchor fallback/refusal rules; do not change data roots, reset
  storage, widen the readiness deadline, or mutate live PVs outside the next supported reconcile.
- That correction is now closed code-locally. ChartPlatform lists Pods by the exact Percona cluster
  and `role=primary` labels, accepts exactly one Pod with exactly one `postgres-data` PVC, verifies
  that the claim matches the Pod identity with its terminal ordinal removed, and follows the claim
  to its bound PV. Empty, multiple, malformed, identity-mismatched, unbound, or non-owned
  observations still take the existing no-live-anchor fallback/refusal path. The anchor-aware
  binding regression uses the observed random suffixes and proves retained PV0 remains on `hh5k`,
  retained PV1 moves to the new `5krm` follower, and retained PV2 remains on `rwr7`; data roots,
  storage reset policy, readiness budgets, and mutation ownership are unchanged. Parser/fallback
  cases pass **3/3**, the random-suffix binding case passes **1/1**, and the installed staged-restore
  boundary passes **1/1** while proving no Endpoint `targetRef` query remains. The shared installed
  fixture now models exact Secret `create -f` and decodes retain versus restore on the authenticated
  Authority workflow route; its Gateway OOM case deterministically proves installed fail-fast
  behavior while the pure suite retains the absorbing-across-later-healthy proof. The complete
  primary suite passes **4833/4833** in 91.21 seconds, auxiliaries pass **27/27**, **35/35**, and
  **36/36**, and both installed integration entrypoints pass **63/63** (`cli` in 441.88 seconds and
  `env` in 437.41 seconds). Warning-as-error all-target compilation, documentation/diff checks, and
  canonical `prodbox dev check` pass with pinned Fourmolu and HLint `No hints`. The gate-built
  executable and `.build/prodbox` are byte-identical at
  `sha256:1e8a5182230c2b67f1fb14da71955eb702b778d24a4d562511674f1a493e55cb`. Rerun the exact
  unchanged live `pre-1` cycle to repair the retained PV binding through the supported reconcile
  and close this counterexample before returning to the TLS attach counterexample. Deployment
  qualification remains `pending`: no qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- The exact corrective live `pre-1` rerun builds local runtime image
  `sha256:29ac372d3a008fedf205b5fdb59bfbf1f63b424eed1d64bbaaf470299af0e584` in
  1,386.2 seconds, publishes registry manifest
  `sha256:b447c3dceffb721bd8d2698f11c12156c109be8d9a7b98309ee146348b876eb3`, and
  imports OCI manifest `sha256:40a15569bcbcaace92fe18dba5ed8684f90193b922612ca804032da97dcbdb13`
  in 116.1 seconds. It removes only the superseded registry manifest `sha256:e571c53f...` and local
  image `sha256:9d2a79b5...`, then passes the retained Bootstrap Broker, Target Agent, Lifecycle
  Authority, Authority Backup, Provider Worker, Gateway, TLS Retention, and shared-platform
  barriers. The total restore executor proves every chart deletion with storage preservation plus
  Gateway, API, and WebSocket reconstruction, but VS Code fails before its release apply at the
  public-edge TLS restore preamble with `TlsRetentionWorkflowAuthorityHomeAgentUnavailable`;
  public-edge readiness independently retains the known Gateway-DNS write-authority refusal. The
  only licensed standing diagnostics select Target Agent
  `target-one-shot/tls-home-rewrap failure=coordinator/session-prepare-failed` and Authority
  `tls-retention/workflow failure=home-agent/http-status/other`. Stable counterexample
  `TLS-RETENTION-HOME-REWRAP-SESSION-PREPARE-FAILED-2026-09-04` owns this boundary before any
  change to worker-session preparation, home rewrap, transport, deadlines, cleanup, or TLS workflow
  behavior. Because `ensureChartStorage` precedes this TLS preamble while Helm apply and staged
  Patroni readiness follow it, the run exercises the corrected storage preparation but does not
  yet live-close `VSCODE-RESTORE-PATRONI-THREE-REPLICA-READINESS-TIMEOUT-2026-09-04`; the earlier
  `TLS-RETENTION-PREPARE-ATTACH-TRANSPORT-UNAVAILABLE-2026-09-04` also remains not live-closed.
  Exact terminal cleanup is not proved, so operational credentials remain preserved. No
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole. Diagnose session preparation from source and exact non-secret
  worker object/status/event observations without widening the licensed log surface.
- That permitted read-only diagnosis proves the exact home-rewrap one-shot Job and Pod were
  created, scheduled, pulled, started, and then UID-cleaned; no one-shot Job or worker Pod remains.
  The VS Code namespace contains only its restored editor PVC and no PostgreSQL CR/PVC/PV because
  the TLS preamble refused before the staged Patroni release apply, confirming the Patroni
  counterexample remains live-open. Source inspection shows the post-attestation coordinator calls
  retained service-session allocation and preparation before permit issuance or stdin attach, but
  its production interpreter converts every closed `ServiceSessionLifecycleError` to bounded
  `Text` and the diagnostic collapses every such value to `session-prepare-failed`. Add only a
  behavior-neutral, exhaustive, value-free session-preparation cause projection across that
  boundary; retain payload/detail erasure and all journal, cleanup, permit, attach, and TLS behavior
  unchanged. Validate locally, then rerun the same `pre-1` to select the exact retained-journal,
  preclean, CAS, or ambiguity arm.
- That diagnostic refinement is now closed code-locally. The coordinator initially carries a fifteen-member
  `TargetWorkerSessionPrepareCause` ADT instead of arbitrary detail; the production interpreter
  maps every `ServiceSessionLifecycleError` constructor to it exhaustively, and the protected
  renderer emits only fixed `session-prepare-failed/...` tokens. Journal, Vault, audit, and action
  detail is erased before the coordinator while allocation, fencing, preclean, cleanup, permit,
  attach, deadlines, and TLS behavior remain unchanged. The exact closed-vocabulary/detail-erasure
  regression passes **1/1**. Warning-as-error all-target compilation passes; the canonical unit
  command passes primary **4834/4834** plus auxiliaries **27/27**, **35/35**, and **36/36**. Both
  installed integration entrypoints pass **63/63** (`cli` in 447.84 seconds and `env` in 438.57
  seconds), and canonical `prodbox dev check` passes with pinned formatting, HLint `No hints`,
  governed documentation, and warning-clean all-target compilation. Documentation lint and diff
  checks pass; the gate-built executable and `.build/prodbox` are byte-identical at
  `sha256:d87676ec2a6de0befd5665dac151c06f9897d76e61eda46f25320d4ce985a892`. Rerun live
  `pre-1` unchanged on this diagnostic-only revision and use its exact value-free
  session-preparation arm before any behavior change; all three live counterexamples and deployment
  qualification remain pending, and the legacy public writer remains sole.
- The unchanged diagnostic `pre-1` rerun uses local runtime image
  `sha256:fdb7573fb63699ab9c80349bf14e2ae844579f818e061a88176ab4f06ba99200`, publishes
  registry manifest `sha256:7c3294916ac932ed55700b9468206e0839190260e3915aa63a6f4f41d62bb91f`,
  and imports OCI manifest
  `sha256:178e6bfe3633546f3ace234491f6987309a9fa4ae6ce7b7275b21e78590652b6` in
  108.9 seconds. It removes only the preceding registry manifest `sha256:b447c3d...` and local
  runtime image `sha256:29ac372d...`, passes the retained control-plane and shared-platform
  barriers, and again proves all four chart deletions plus Gateway, API, and WebSocket restoration.
  VS Code refuses before release apply at `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`;
  the licensed standing diagnostics select Target Agent
  `target-one-shot/tls-restore failure=coordinator/session-prepare-failed/preclean-failed` and
  Authority `tls-retention/workflow failure=selected-agent/http-status/other`. Stable
  counterexample `TLS-RETENTION-SELECTED-RESTORE-SESSION-PRECLEAN-FAILED-2026-09-04` owns this
  boundary before any change to session preclean, retained-session recovery, Target Agent
  selection, TLS restore, transport, deadlines, or cleanup. This different selected-agent arm
  does not live-close `TLS-RETENTION-HOME-REWRAP-SESSION-PREPARE-FAILED-2026-09-04`,
  `TLS-RETENTION-PREPARE-ATTACH-TRANSPORT-UNAVAILABLE-2026-09-04`, or
  `VSCODE-RESTORE-PATRONI-THREE-REPLICA-READINESS-TIMEOUT-2026-09-04`. Exact terminal cleanup is
  not proved, operational credentials remain preserved, no qualification artifact or activation
  witness exists, and the legacy public writer remains sole. Diagnose preclean and retained-session
  recovery from source and exact non-secret worker object/status/event observations without
  widening the licensed log surface.
- That permitted diagnosis isolates the next ambiguity without changing behavior. The exact
  `tls-restore` worker was created, scheduled, pulled, and started at 18:10:09--10 UTC, then
  UID-cleaned at 18:10:15; no one-shot Job or worker Pod remains, and the exact-image standing
  Target Agent remains Ready. For each operation the agent obtains a fresh accessor-free batch
  auditor with a maximum 300-second lease, uses that same capability to allocate and begin the
  retained role lane, and only then reaches `ServiceSessionAcquiring` preclean. Preclean lists the
  global accessor inventory, classifies each accessor against the role-wide Target-worker subject,
  provisionally revokes matches, and requires two fresh zero-member observations. The lifecycle
  error retains a closed `VaultAccessorAuditError`, but the production projection collapses all of
  its identity, auditor-evidence, inventory-observation, accessor-classification, known-identity,
  revocation, visibility-wait, and stable-absence arms to `preclean-failed`. Add only an exhaustive,
  value-free preclean-cause projection and fixed Target-Agent token, preserving private provider
  detail and all policy, login, lease, journal, retry, revoke, cleanup, permit, attach, deadline,
  and TLS behavior. Validate locally, then rerun the same `pre-1` before licensing any behavior
  correction for `TLS-RETENTION-SELECTED-RESTORE-SESSION-PRECLEAN-FAILED-2026-09-04`.
- The nested preclean diagnostic is now code-local. The former undifferentiated preclean constructor
  is replaced by nine fixed constructors covering every `VaultAccessorAuditError`; production maps
  that closed algebra exhaustively, and the renderer emits only `preclean/...` tokens with no
  provider, accessor, journal, or payload detail. The accessor auditor, role-wide subject, policy,
  lease, inventory/classification/revoke algorithm, visibility budget, session journal, permit,
  attach, cleanup, deadlines, and TLS workflow are unchanged. Warning-as-error all-target
  compilation passes, and the focused exhaustive vocabulary/mapping/detail-erasure regression
  passes **1/1**. The canonical unit command passes primary **4834/4834** plus auxiliaries
  **27/27**, **35/35**, and **36/36**. Both installed integration entrypoints pass **63/63** (`cli`
  in 441.57 seconds and `env` in 439.14 seconds); canonical `prodbox dev check` passes with pinned
  formatting, HLint `No hints`, governed documentation, and warning-clean all-target compilation,
  and diff checks pass. The gate-built executable and `.build/prodbox` are byte-identical at
  `sha256:358a50564a02e314fa97a0b8db38e20328962059b516872f59ddd616311fb35b`. Rerun the same
  live `pre-1` on this diagnostic-only revision to select the exact preclean stage before changing
  behavior.
- The exact diagnostic `pre-1` rerun builds local runtime image
  `sha256:afb6b65b41a96df2892f72bb3fdc17dab3592a5673e9833154c1c76abcbd1938` in 1,157.1
  seconds, publishes registry manifest
  `sha256:632e33170147cdcff3be0362d93077ff3aae2aebbf8f77470b4da968476798c7`, and imports OCI
  manifest `sha256:24124eeae71681a4b131da087daa323023bd9ee97182067732ffacd944f1185d` in 85.3
  seconds. It removes only the preceding registry manifest `sha256:7c329491...` and local image
  `sha256:fdb7573f...`, crosses every retained control-plane, shared-platform, Provider, Gateway,
  TLS Retention, and runbook barrier, and proves all four chart deletions plus every Gateway, VS
  Code, API, and WebSocket restore node. The Percona cluster is `ready`: exact Pods `r6p5` primary
  plus `8lw2` and `xnr2` replicas are Running with both containers Ready and zero restarts;
  retained PV0 is bound to the primary claim while PV1/PV2 bind the two follower claims. This
  live-closes `VSCODE-RESTORE-PATRONI-THREE-REPLICA-READINESS-TIMEOUT-2026-09-04`. The licensed
  Target Agent log is empty and the Authority log contains only
  `aws-admin/prepare authority-phase=completed`, so the run selects no TLS failure and does not
  close the intermittent selected-restore preclean, home-rewrap session-prepare, or prepare-attach
  counterexamples. The sole aggregate failure is now public-edge readiness:
  `Gateway-DNS observation is bound to the requested record but its write authority is not ready`.
  Stable counterexample
  `HOME-PUBLIC-EDGE-GATEWAY-DNS-WRITE-AUTHORITY-NOT-READY-2026-09-04` owns this boundary before any
  change to Gateway credentials, DNS authority construction, status projection, record
  reconciliation, readiness, or public-edge behavior. Exact terminal cleanup remains unproved,
  operational credentials remain preserved, no qualification artifact or activation witness
  exists, and the legacy public writer remains sole. Diagnose Gateway-DNS authority from source
  and exact non-secret Gateway object/status observations without widening the licensed log
  surface.
- That diagnosis selects nested stable counterexample
  `GATEWAY-RESTORE-PEER-SNAPSHOT-HEARTBEAT-EVIDENCE-UNEXPECTED-2026-09-04`. The restored
  `gateway-node-a` and `gateway-node-b` StatefulSets are generation 1, fully observed, Ready with
  zero restarts, and run registry manifest `sha256:632e3317...`; the public-edge Gateway is
  Accepted/Programmed at observed generation 1 with address `192.168.2.240`. Repeated exact
  `/v1/state` observations reach both members and show `gateway_owner=null`,
  `node_disposition=unknown`, `can_write_dns=false`, no last DNS write, and Ready retained
  continuity. Node A receives fresh Node-B events but its outbound repair stops at exact
  `PeerSnapshotEvidenceUnexpected (NodeId "node-a") SnapshotHeartbeatEvidence`; Node B's peer
  socket is reachable while it receives no fresh Node-A event. Source establishes that
  `retainSignedAssertion` prunes signed replay only before inserting an assertion, whereas restart
  restoration installs the already-final semantic checkpoint before folding the retained signed
  suffix. An inserted assertion already at or below that checkpoint can remain in replay, and its
  signed checkpoint projection can retain heartbeat evidence that an Orders-migration checkpoint
  has semantically cleared. Repair signing correctly refuses the mismatch, leaving both nodes
  ownerless and DNS authority closed. Reconcile signed retention after insertion against the
  installed semantic checkpoint, preserving only strictly post-checkpoint replay and applying
  heartbeat/ownership/migration evidence in order; add a focused restart/repair regression, keep
  signature and peer rejection semantics unchanged, validate locally, then rerun exact `pre-1`.
  The broader Gateway-DNS counterexample, all intermittent TLS counterexamples, exact cleanup,
  qualification artifact, activation witness, and single-writer cutover remain open.
- The signed-retention correction is now code-local. `SignedEmitterRetention` gives each emitter
  one exact heartbeat slot, one exact ownership slot, and one bounded signed suffix; every
  insertion reconciles both before and after capacity handling against the installed semantic
  checkpoint using the full incarnation/epoch/sequence coordinate. Exact semantic comparison
  drops mismatched or semantically absent checkpoint evidence, and an Orders-migration assertion
  clears both slots before repair signing. Daemon recovery folds checkpoint evidence and its
  retained suffix through that one projection; peer and ordinary publication paths use the same
  invariant. Signature verification, checkpoint construction, peer rejection, durable journal,
  ownership election, and DNS behavior are otherwise unchanged. Warning-as-error all-target
  compilation passes. The focused restored-migration counterexample passes **1/1**, and the
  complete bounded-Gateway group passes **44/44**. Complete unit validation passes primary
  **4835/4835** plus auxiliaries **27/27**, **35/35**, and **36/36**. Both installed integration
  entrypoints pass **63/63** (`cli` in 446.16 seconds and `env` in 446.07 seconds). Canonical
  `prodbox dev check` passes with the pinned formatter, HLint `No hints`, policy and
  generated-document checks, and warning-clean all-target compilation; the final
  ledger-inclusive rerun also passes. Documentation lint and diff checks pass. The gate-built and
  installed executables are byte-identical at
  `sha256:6a15f363b8ad723245f07d7ea7d29ac180774f374a8a8d3168478fbab5755afd`. Live `pre-1`
  validation remains next; no live counterexample is closed yet.
- The exact corrected `pre-1` rerun builds local runtime image
  `sha256:8df0881503a61cee043b2095edad36eddb38c01a7f6c68928566cf5386278ff7`, publishes
  registry manifest `sha256:52da546accedd42b046c5d4f03db47dfe4039e2c13e2b775604afea29e134082`,
  and imports OCI manifest
  `sha256:c0613c089779c56a6123eb9de580f636c785aa50d16c9ec96e3a968dd1c77dd2` in 113.8
  seconds. It removes only the preceding registry manifest `sha256:632e3317...` and local image
  `sha256:afb6b65b...`, crosses the retained control-plane and platform prerequisites, and proves
  the four chart deletions, Gateway MinIO bootstrap, and all four chart restores. Only
  `RestoreNodeWaitForPublicEdge` fails, with exact refusal `Gateway-DNS observation is bound to
  the requested record but its write authority is not ready`; exact terminal cleanup is therefore
  not proved and operational credentials remain preserved. Both Gateway StatefulSets are Ready
  with zero restarts on the exact corrected registry manifest. Their continuity, connected-peer,
  inbound-event, and cursor observations are healthy, and the former
  `PeerSnapshotEvidenceUnexpected ... SnapshotHeartbeatEvidence` refusal is absent. This
  live-closes
  `GATEWAY-RESTORE-PEER-SNAPSHOT-HEARTBEAT-EVIDENCE-UNEXPECTED-2026-09-04`. The licensed Target
  Agent log is empty and the Authority log contains only
  `aws-admin/prepare authority-phase=completed`, so this run selects no TLS failure and leaves all
  three intermittent TLS counterexamples open. Repeated exact member observations instead select
  stable counterexample
  `GATEWAY-RESTORE-LEGACY-HEARTBEAT-CADENCE-EXCEEDS-FRESHNESS-WINDOW-2026-09-04` before changing
  Gateway timing. Production still selects `LegacyModelBEmitter`: it timestamps a heartbeat
  before the full persistence-first remote Model-B emission, waits for that emission, and only
  then sleeps the configured 0.5-second interval. A 20-second two-member sample shows accepted
  heartbeats first visible about 4.9–6.1 seconds old, recurring about every 10 seconds and
  reaching 15.96 seconds old, while the explicit Orders heartbeat timeout is only 5 seconds.
  Owner projections appear only briefly at 4.898- and 4.984-second peer ages, never form an active
  claim, and return to null as the evidence expires; DNS write authority consequently remains
  closed. Raise the explicit rendered pre-cutover Orders heartbeat timeout to 30 seconds, within
  the canonical timing bounds and with measured legacy-path margin, rather than hiding a
  topology-specific runtime override. Preserve the 0.5-second heartbeat/reconnect intervals,
  one-second sync interval, signatures, claims, DNS gates, and target local-journal semantics; add
  exact render/config regressions and document why the mutually exclusive legacy topology needs
  this temporary timing accommodation. Validate locally, then rerun exact `pre-1`. The broader
  Gateway-DNS counterexample, intermittent TLS counterexamples, exact cleanup, qualification
  artifact, activation witness, and single-writer cutover remain open; the legacy public writer
  remains sole.
- The explicit pre-cutover timing correction is now code-local. Both the bare Gateway chart and
  the production `ChartPlatform` projection render a 30-second Orders heartbeat timeout; the
  0.5-second heartbeat/reconnect intervals and one-second sync interval are unchanged. Distributed
  Gateway doctrine records the measured legacy persistence-path reason, forbids a hidden
  topology-selected override, and keeps any later target-journal reduction behind its own
  registered and qualified change. Warning-as-error all-target compilation passes. The exact
  production-plan timing regression and exact bare-chart-default regression each pass **1/1**,
  and the complete canonical unit command passes primary **4836/4836** plus auxiliaries
  **27/27**, **35/35**, and **36/36**. Both installed integration entrypoints pass **63/63**
  (`env` in 444.63 seconds and the uncontended `cli` rerun in 451.26 seconds); an earlier
  concurrent `cli` invocation is excluded because Cabal lost its shared suite log while `env`
  owned it, before any test result. Canonical `prodbox dev check` passes with repository-pinned
  Fourmolu 0.19.0.1, HLint `No hints`, policy, generated-document, and warning-clean all-target
  compilation. The gate-built and installed executables are byte-identical at
  `sha256:504ccbd7070f67aba8b94a3ee0ebef1f5c02b6a7a24ca941ff5a200f85ceb0a4`, and diff checks
  pass. The ledger-inclusive canonical rerun, governed-document lint, and diff checks also pass.
  Live `pre-1` is next; no live Gateway timing counterexample is closed yet.
- The exact live `pre-1` rerun on that revision builds local runtime image
  `sha256:184d8c2e53b21bdfb637e66df0ddd772e7e0f1628bcd823704e20c652612e846` in
  1160.5 seconds, publishes registry manifest
  `sha256:fe3784d054981137bce4d6fc0230e827805ac7cbf03af55ea47c742c9fd3c8fb`, and
  imports OCI manifest
  `sha256:85c54ee8024f975e862924c7d4a4f74bd08e40aa373f173c097fce79899f2215` in
  107.4 seconds. It removes only the superseded registry manifest
  `sha256:52da546accedd42b046c5d4f03db47dfe4039e2c13e2b775604afea29e134082` and
  local image `sha256:8df0881503a61cee043b2095edad36eddb38c01a7f6c68928566cf5386278ff7`,
  crosses Bootstrap Broker, Target Agent, Gateway MinIO bootstrap, Lifecycle Authority, Authority
  Backup, MetalLB, Envoy Gateway, cert-manager, the Percona operator, and Provider Worker, and keeps
  retained root session
  `root-session-9c54db6ad0a352d81a4313f7f2613735c056a2b635618cc095bba021a6b21a5b` plus
  digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`
  exact. Gateway reconcile then observes `HTTP 503: starting`, performs the supported sequential
  restart of both daemon StatefulSets, and terminates at `gateway daemon remained not-ready after
  its continuity restart: HTTP 503: starting`; candidate execution is never entered. Exact
  terminal cleanup is not proved, operational credentials remain preserved, and no qualification
  artifact or activation witness exists. The licensed Target Agent log is empty and the Authority
  log again contains only `aws-admin/prepare authority-phase=completed`, so this run selects no TLS
  failure and leaves the three intermittent TLS counterexamples open.
- Stable counterexample
  `GATEWAY-LEGACY-ORDERS-HASH-CHANGE-STRANDS-CONTINUITY-2026-09-04` is registered before another
  behavior change. Both Gateway StatefulSets are subsequently Ready with zero restarts on the exact
  new image, and deployed Orders read-back proves version 1 plus the new 30-second timeout; yet both
  exact member endpoints remain `HTTP 503: starting` more than 400 seconds after restart. Their
  state projections agree on `continuity_authority.status = unavailable`,
  `last_backend_round_trip = null`, no active claim, and connected peer transports with no accepted
  inbound event. This is not a short verifier budget: the verifier already allows 60 attempts at
  two seconds, and the refusal persists far beyond it. The bounded Orders compiler hashes canonical
  CBOR including `heartbeat_timeout_seconds`; legacy continuity binds and validates the retained
  record to the exact Orders version-plus-hash, while the durable admission marker is keyed only by
  node. Changing 5 to 30 under unchanged version 1 therefore makes each existing admitted node
  reject its retained record at startup, and the rollback `LegacyModelBEmitter` has no journal
  Orders-migration bridge. This live counterexample invalidates the 30-second rendering change as a
  deployable correction and leaves
  `GATEWAY-RESTORE-LEGACY-HEARTBEAT-CADENCE-EXCEEDS-FRESHNESS-WINDOW-2026-09-04` open. Restore the
  retained Orders identity and correct the measured persistence/cadence defect without relabelling
  or discarding continuity, weakening readiness, or bypassing the exact Orders-migration contract;
  keep the legacy public writer sole until Standard-P activation. Then validate locally and rerun
  exact `pre-1`. The broader Gateway-DNS counterexample, intermittent TLS counterexamples, exact
  cleanup, qualification artifact, activation witness, and single-writer cutover remain open.
- The retained Orders identity is restored: both chart sources again render version 1 with the
  exact five-second heartbeat timeout. The cadence correction changes the protocol instead of that
  identity. `LegacyModelBEmitter` now commits one ordinary signed heartbeat through its existing
  persistence-first Model-B transaction as a per-process boot fence, then emits HMAC-signed,
  canonical-CBOR, latest-only liveness frames bound to exact Orders, emitter, boot
  incarnation/epoch/sequence/digest, monotonic per-boot sequence, and timestamp. The recurring path
  never enters the capacity-one child lane; claims, yields, rotation, and the boot fence remain
  persisted semantic assertions. Each daemon retains at most one verified frame per bounded member,
  clears it when a newer durable heartbeat is observed, refuses stale/conflicting/regressing/skewed
  frames, and sends liveness only after bounded delta/repair. Stable model counterexample
  `GATEWAY-LEGACY-LIVENESS-SELF-REPLAY-AFTER-CRASH-2026-09-04` found that an initial draft permitted
  a crashed node to accept its own delayed frame. The runtime and model now refuse inbound
  self-delivery and require the local legacy Authority, process-local durable-boot session, and
  matching local frame before ownership. Focused bounded-Gateway validation passes **47/47**. The
  complete unit command now passes primary **4839/4839** plus auxiliaries **27/27**, **35/35**, and
  **36/36**. The canonical formal entrypoint runs both models: the unchanged journal/Lease model passes all 16
  invariants at **7,139,920 generated / 781,710 distinct** states, and the new legacy bridge passes
  all six invariants at **2,092,755 / 441,423** states. Library, executable, and unit-target builds
  complete without warnings. Both installed integration entrypoints pass **63/63** (`cli` in 452.62
  seconds and `env` in 451.57 seconds). Canonical `dev check` passes with repository policy, pinned
  Fourmolu, HLint (`No hints`), and warning-clean all-target compilation. Its gate-built and
  installed executables are byte-identical at
  `sha256:3b265dbc56c2649ba84b658e901a6605993773675880d8bc009d5308170cddbc`. The
  ledger-inclusive canonical rerun, governed-document lint, and diff checks also pass. Exact live
  `pre-1` is next; neither live Gateway counterexample is closed, and the legacy public writer
  remains sole.
- The exact live `pre-1` rerun on that locally green revision builds runtime image
  `sha256:04cd977535aab6bcb1b7e5e10b3bfba4e92977c4330d6f0477d36a07ce17f2ba` in 1129.9
  seconds, publishes registry manifest
  `sha256:276d25ef3d1eb8ff3fbfba67320b9b8265a20a5bc9773f9d3ece68dbd5367b6b`, and imports OCI
  manifest `sha256:17736dcefeee94ed8081e6b1e928c43495b8955340a284a0794fbabed4d34a62` in
  106.8 seconds. It preserves the exact retained Vault root session and digest, crosses Bootstrap
  Broker, Target Agent, Lifecycle Authority, Authority Backup, MetalLB, Envoy Gateway, cert-manager,
  Percona, Provider Worker, and a first full-mode Gateway reconcile without the former continuity
  restart or `HTTP 503: starting`. The runbook's repeated Gateway gate then fails closed at
  `ProbeBackendRoundTrip ComponentMinio`: the observation is stale beyond its freshness window.
  Stable counterexample `GATEWAY-LEGACY-LIVENESS-NO-BACKEND-FRESHNESS-2026-09-04` records that
  bounded liveness ages remain below 1.3 seconds while the sole boot-fence backend round-trip ages
  from roughly 455 to 498 seconds; recurring liveness therefore cannot satisfy the independent
  backend-readiness obligation. The same state trace registers distinct counterexample
  `GATEWAY-LEGACY-LIVENESS-ASYMMETRIC-REJECTION-SPLIT-OWNER-2026-09-04`: node A accepts node B's
  frame, node B rejects node A's bounded liveness, and both report an active self-owned claim. The
  exact receiver refusal arm must be diagnosed before changing admission or clock-skew behavior.
  No qualification artifact or activation witness exists, exact cleanup is unproved, operational
  credentials remain preserved, and the legacy public writer remains sole.
- Both registered Gateway counterexamples now have a local correction, without changing retained
  Orders, the five-second freshness rule, or the legacy public writer. Liveness protocol version 2
  outer-signs the complete signed semantic boot heartbeat as well as its derived fence. A receiver
  with no latest-heartbeat projection may admit it only when its compacted cursor is at the exact
  boot/digest or later in the same incarnation and epoch; behind, conflicting, later-incarnation,
  and later-epoch states remain closed. A separate supervised `backend_round_trip` worker commits a
  normal persistence-first heartbeat on a 60-second post-attempt cadence, refreshes the
  write-shaped MinIO receipt inside the unchanged 300-second readiness window, and replaces the
  process-local liveness session at sequence one. The hot liveness worker remains outside the
  capacity-one child lane. The warning-clean executable/unit build succeeds and the focused
  signed-liveness group passes **3/3**, including exact, later compacted-cursor, conflicting-digest,
  stale-fence, self-delivery, and forged frame cases. The extended canonical TLA run keeps the
  target journal model exact at **7,139,920 generated / 781,710 distinct** states and passes all six
  legacy invariants at **14,683,109 / 2,233,608** states, covering in-process proof rotation,
  compacted-cursor admission, and delayed predecessor rejection. The full local gate set now passes:
  primary unit **4839/4839** plus auxiliaries **27/27**, **35/35**, and **36/36**;
  installed `cli` integration **63/63** in 444.26 seconds; installed `env` integration **63/63** in
  446.32 seconds; and canonical `dev check` with repository policy, pinned Fourmolu, HLint (`No
  hints`), generated-document checks, and warning-clean all-target compilation. The gate-built and
  installed executables are byte-identical at
  `sha256:cb16c900d6d221e2aedc7d4fe7499f817e6b7a4d320b66ab7fa7d2b381d275a4`. Exact live
  `pre-1` is next; neither live counterexample is claimed closed yet.
- The exact corrected live `pre-1` advances beyond both registered Gateway counterexamples on local
  runtime image `sha256:6f812f21e43391f4d551d73c323bcd2158b7dccb8aa1bb1b487d915b4031d277`,
  registry manifest `sha256:483099997ab1f45168348dae3a15677f55c17ee5e91e08beeb9837466f296827`,
  and OCI import manifest
  `sha256:51fabc0a2e04a55af4e27bf14594c4938f300e661a3d2d3b84c0b6fa2521111f`.
  The repeated Gateway gate crosses backend-round-trip readiness and bidirectional liveness, the
  total-restore program proves all four chart deletions and reconstructions, and the restored home
  edge reaches `CLASSIFICATION=ready-for-external-proof` with Route 53 in sync, accepted Gateway,
  listeners and routes, a current certificate, and private-edge readiness. This live-closes
  `GATEWAY-LEGACY-LIVENESS-NO-BACKEND-FRESHNESS-2026-09-04` and
  `GATEWAY-LEGACY-LIVENESS-ASYMMETRIC-REJECTION-SPLIT-OWNER-2026-09-04`. Candidate preparation then
  reaches registered stack creation, which is admitted but not executed because Lifecycle Authority
  refuses its lifecycle generation at
  `AwsStackCreationFieldInvalid "AwsStackCreationWireCommitPayloadInvalid \"AwsStackCreationFieldInvalid \\\"AWS scope is missing\\\"\""`.
  Stable counterexample `AWS-QUALIFICATION-REGISTERED-STACK-GENERATION-SCOPE-MISSING-2026-09-04`
  owns this exact commit-payload/generation boundary. Exact terminal cleanup is not proved,
  operational credentials are preserved for recovery, no qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
  Diagnose the registered generation's admitted Provider-scope producer and retained read-back before
  changing execution, fallback, or cleanup behavior.
- The missing-scope counterexample is now closed code-locally at its exact producer boundary. The
  Authority no longer reuses the caller's deliberately scope-less creation envelope for the legacy
  run-scoped binding. After committing and independently reading back the durable generation, it
  derives that binding's registry revision, foundation, run scope, surface, AWS account, and AWS
  region from the committed generation itself; the account and region therefore still enter only
  through the retained Provider proof, and the two records cannot diverge. The focused production
  producer/consumer group passes **4/4**, including a production-shaped `AWS = Nothing` caller and
  an exact read-back under the Provider-proven scope. The full unit matrix passes primary
  **4840/4840** plus auxiliaries **27/27**, **35/35**, and **36/36**. Installed
  `clean-room-handoff` passes the complete qualification-only plan and
  success/failure/cancellation/response-loss/restart fake matrix. Canonical `prodbox dev check`
  passes repository policy, pinned Fourmolu, HLint (`No hints`), generated-document checks, and
  warning-clean all-target compilation. The gate-built and installed executables are byte-identical
  at `sha256:9f2857d24dae42ef9c08c71778f4cc77f9b78724895f8ca89531a58a5cdd5e69`.
  Rerun exact live `pre-1`;
  `AWS-QUALIFICATION-REGISTERED-STACK-GENERATION-SCOPE-MISSING-2026-09-04` is not live-closed by
  local evidence, no qualification artifact or activation witness exists, no preactivation cycle
  has passed, and the legacy public writer remains sole.
- The 2026-09-05 exact live `pre-1` retry publishes local runtime image
  `sha256:add730adb2c07793f3962da7f8391acc13cd5c69fe85db1380607bcb93494563`, registry
  manifest `sha256:64a8521c29616daf72318228e9e2c39dcfd767a4c6d2204cd2195c6e15e79837`, and OCI import
  manifest `sha256:8aa692ec2bcb875d4128fee4ba16c2f896f86700771533d98df5e00f72449835` while preserving
  the exact retained Vault root and storage generation. It crosses the first home reconcile, the
  repeated Phase-1.5 Gateway barrier, and begins Phase 1.6 total restore. An operator-requested
  Ctrl-C during the Gateway restore, after the Gateway MinIO bootstrap Job completed and was
  deleted, terminates the command at exit 1 with uncaught
  `GHC.Internal.IO.Exception.BlockedIndefinitelyOnSTM` instead of a durable cancellation result.
  Stable counterexample `CASCADE-QUALIFICATION-CTRL-C-BLOCKED-INDEFINITELY-ON-STM-2026-09-05`
  owns this subprocess/cancellation boundary. The run never reaches registered stack creation, so
  it does not live-close
  `AWS-QUALIFICATION-REGISTERED-STACK-GENERATION-SCOPE-MISSING-2026-09-04`; exact terminal cleanup
  is unproved, the previously preserved operational-credential state is unresolved, no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole. Reproduce the cancellation at a non-mutating streamed-child
  boundary and diagnose the exact parent/child lifetime owner before rerunning live qualification.
- The cancellation counterexample is now closed at the production streaming boundary. The exact
  non-mutating reproduction first emitted the same uncaught `BlockedIndefinitelyOnSTM`: with
  delegated Ctrl-C, `process` throws `UserInterrupt` synchronously in the thread calling
  `waitForProcess`, while `typed-process` had placed that wait in a private reaper which could exit
  before filling its exit-code `TMVar`. `runStreaming` now keeps `delegate_ctlc = True` but uses the
  `process` bracket and waits in the calling command thread, leaving captured, bounded, and
  background subprocess ownership unchanged. The process-group regression is red-before and
  green-after at **1/1**, observes exact `ExitFailure (-2)`, and emits no stdout or stderr;
  manually interrupting the installed `prodbox test unit` streaming path now terminates with only
  `^C` and no uncaught exception. The complete unit matrix passes primary **4840/4840** plus
  auxiliaries **27/27**, **35/35**, and **36/36**; installed `cli` passes **64/64**; canonical
  `prodbox dev check` passes repository policy, pinned Fourmolu, HLint (`No hints`),
  generated/documentation checks, and warning-clean all-target compilation. The installed
  `clean-room-handoff` validation also revalidates the complete qualification-only plan and
  success/failure/cancellation/response-loss/restart fake matrix. The gate-built and installed
  executables are byte-identical at
  `sha256:a861a2eb6190a33fcf9174623c3ed52cdc3c6f99bf76997fe07d84b16f344897`. Rerun exact
  live `pre-1`; the missing-scope counterexample remains unproved live, no qualification artifact
  or activation witness exists, no preactivation cycle has passed, and the legacy public writer
  remains sole.
- The exact 2026-09-05 `pre-1` rerun builds local runtime image
  `sha256:4fbe30aec62dcf80259a09c46cfc12e5ee04a0f32b6b36b24564870682311762` in 1,010.1
  seconds, publishes registry manifest
  `sha256:0916f16bc5da7a609e2d81a1797ebb2460135ace803e40c3a38aaf8b096431ac`, and imports OCI
  manifest `sha256:7a0bacd62ef3e04d6566a72a6fd20f3127b01480f61f622f48da89580a1eb6b5` in 84.1
  seconds while deleting only the superseded runtime identity. It preserves exact retained root
  session `root-session-9c54db6a...`, Vault storage generation `vault-a290544e...`, and read-back
  digest `a5756119...`, then reaches Bootstrap Broker, Target Agent, Lifecycle Authority, and
  Authority Backup reconciliation. Before candidate execution, harness in-force config sync
  refuses because its caller-bound Transit signer cannot resolve absent ServiceAccount
  `gateway/prodbox-control-plane-test-harness`. Stable counterexample
  `CASCADE-QUALIFICATION-HARNESS-CALLER-SERVICEACCOUNT-ABSENT-2026-09-05` owns this recovery
  prerequisite ordering after the prior interrupted Gateway restore. Diagnose the caller
  identity's exact chart/lifetime owner and establish it through that owner before sync; do not
  bypass caller-bound authentication or widen credentials. The run does not reach registered
  stack creation, so the missing-scope counterexample remains unproved live. Exact terminal
  cleanup is unproved, the prior preserved operational-credential state remains unresolved, no
  qualification artifact or activation witness exists, no preactivation cycle has passed, and the
  legacy public writer remains sole.
- That caller-lifetime counterexample is now closed code-locally without moving or recreating the
  Gateway-owned identity. The successful cluster-backed bootstrap floor already includes
  `StepReconcileInForceConfig` and submits/read-backs the exact generated proposal through the
  retained bootstrap-core operator identity; `TestRunner` now recognizes that proof and does not
  immediately duplicate the proposal through a Gateway-lifetime caller. Harness-only suites,
  which establish no runtime floor, retain their authenticated standalone harness sync. The two
  exact pure branch regressions pass **1/1** each, the complete unit matrix passes primary
  **4840/4840** plus auxiliaries **27/27**, **35/35**, and **36/36**, and installed
  `clean-room-handoff` revalidates the complete qualification-only fake matrix. Canonical `prodbox
  dev check` passes repository policy, pinned Fourmolu, HLint (`No hints`),
  generated/documentation checks, and warning-clean all-target compilation. The gate-built and
  installed executables are byte-identical at
  `sha256:c911247fd022cbc1d7522f93115db528eef9e9bc314102d0127b4e6779059e67`. Rerun exact
  live `pre-1`; neither this counterexample nor the registered-generation missing-scope
  counterexample is live-closed by local evidence, no qualification artifact or activation
  witness exists, no preactivation cycle has passed, and the legacy public writer remains sole.
- The exact live rerun of that correction disproves closure and keeps
  `CASCADE-QUALIFICATION-HARNESS-CALLER-SERVICEACCOUNT-ABSENT-2026-09-05` open. It builds local
  runtime image `sha256:4fa4bb878aecd393c1fc7b815ee5f07de32fffa79816bb3d1876506722f3950e`,
  publishes registry manifest
  `sha256:84f083ba7e46e7d3cc05460e778058abf4ca327af266361586188612ea53befe`, and imports OCI
  manifest `sha256:43f434e59608497f358106148cc26d9c7cedecf38e3d035c995b217d6ee1ec5e`, deleting only
  the superseded preceding runtime image. It again preserves root session
  `root-session-9c54db6a...`, Vault storage generation `vault-a290544e...`, and read-back digest
  `a5756119...`; it reconciles Bootstrap Broker, Target Agent, Lifecycle Authority, post-unseal
  handoff, and Authority Backup. After the now-skipped duplicate config sync, a later pre-Gateway
  operation still attempts to resolve the absent `gateway/prodbox-control-plane-test-harness`
  caller-bound Transit signer and terminates non-zero before candidate execution. Trace that
  remaining caller and correct its owner/lifetime ordering without recreating the Gateway-owned
  identity, bypassing caller-bound authentication, or widening credentials. Exact terminal cleanup
  is unproved and operational credentials remain preserved; the registered-generation missing-scope
  counterexample remains unproved live, no qualification artifact or activation witness exists, no
  preactivation cycle has passed, and the legacy public writer remains sole.
- The remaining caller-lifetime defect is now closed code-locally at the credential-repair trigger.
  `reconcileHarnessLifecycleProviderCredential` was the later pre-Gateway operation and had
  hard-coded the removable test-harness caller even though the authentication registry already
  admits both external callers to the exact Credential Provisioner route. It now consumes the
  named invariant `harnessLifecycleProviderCredentialCaller = LifecycleAuthorityOperator`, whose
  bootstrap-core ServiceAccount survives the recovery deletion scope. The harness's stable
  operation scope, simulated prompt, signed permit, downstream worker identities, route trust, and
  credential boundaries are unchanged; no identity is recreated and no trust or credential is
  widened. The exact cascade planning/caller regression passes **1/1**, the complete unit matrix
  passes primary **4840/4840** plus auxiliaries **27/27**, **35/35**, and **36/36**, installed
  `clean-room-handoff` passes its complete qualification-only fake matrix, and canonical `prodbox
  dev check` passes repository policy, pinned Fourmolu, HLint (`No hints`),
  generated/documentation checks, and warning-clean all-target compilation. The gate-built and
  installed executables are byte-identical at
  `sha256:4349faad5d88134b11684abc86cd5e832b9bd75ea76122f202023152456b16a8`. Rerun exact
  live `pre-1`; `CASCADE-QUALIFICATION-HARNESS-CALLER-SERVICEACCOUNT-ABSENT-2026-09-05` and the
  registered-generation missing-scope counterexample both remain open until live evidence crosses
  their boundaries, no qualification artifact or activation witness exists, no preactivation cycle
  has passed, and the legacy public writer remains sole.
- The exact live rerun closes
  `CASCADE-QUALIFICATION-HARNESS-CALLER-SERVICEACCOUNT-ABSENT-2026-09-05` on local runtime image
  `sha256:2504aa26300088848657e4b658215ce52ab96e44349d2212afb8e7a5bbb1557a`, registry manifest
  `sha256:187da2dff0008447618f1c964d86f825cbb5bda127bd74dc108dfd92f48a3213`, and OCI import
  manifest `sha256:a9b1b85c4b8f7722c5f859b8b40ec67aff898f1e3a0e1f3b06ecb81774bdc3a0` after a
  1,008.1-second build and 98.9-second import. It removes only the superseded preceding runtime,
  preserves the exact root session, Vault storage generation, and read-back digest, authenticates
  through the retained caller, confirms Lifecycle-provider generation 2, restores the proper
  Gateway-owned caller through Gateway reconciliation, and crosses both complete home/runbook
  reconciles. Phase 1.6 then reselects existing umbrella counterexample
  `TLS-RETENTION-RESTORE-SELECTED-AGENT-UNAVAILABLE-2026-09-04`: VS Code deletion refuses at
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`. The total executor still proves the
  other three chart deletions and all four chart reconciles, after which public-edge readiness
  reselects `HOME-PUBLIC-EDGE-GATEWAY-DNS-WRITE-AUTHORITY-NOT-READY-2026-09-04`. Use only the
  licensed Target-Agent and Authority logs to select the exact TLS nested arm before changing
  behavior; treat the public-edge refusal as an independent aggregate result until its source-local
  state is re-observed. Candidate execution and registered stack creation are not reached, so
  `AWS-QUALIFICATION-REGISTERED-STACK-GENERATION-SCOPE-MISSING-2026-09-04` remains unproved live.
  Exact terminal cleanup is unproved and operational credentials remain preserved; no qualification
  artifact or activation witness exists, no preactivation cycle has passed, and the legacy public
  writer remains sole.
- The licensed post-terminal diagnostics select a new exact nested branch. Target Secret Agent
  emits only `target-one-shot/tls-retain failure=coordinator/materialization-refused/tls-retain/
  secret-unavailable`, while Lifecycle Authority emits the expected closed outer
  `tls-retention/workflow failure=selected-agent/http-status/other` plus the unrelated completed
  AWS-admin replay. Stable counterexample
  `TLS-RETAIN-PUBLIC-EDGE-SECRET-UNAVAILABLE-2026-09-05` owns the retain-before-delete source
  observation boundary. Diagnose the exact non-secret `vscode/public-edge-tls`
  Secret/Certificate presence, metadata/status, chart ownership, and the closed production
  observer before changing TLS retention, source selection, restore ordering, absence handling, or
  cleanup. The independent Gateway-DNS readiness refusal and every previously open intermittent TLS
  branch remain open; exact cleanup, candidate execution, registered-stack scope proof,
  qualification artifact, activation witness, preactivation cycle, and writer cutover remain
  unproved.
- Exact non-secret diagnosis licenses only the missing graph edge. Target worker API egress has
  survived since 2026-09-02 and current authorization is `yes`, but the exact-name `vscode` Role and
  RoleBinding were created at `08:07:27Z` by the later restore; its restored TLS Secret follows at
  `08:07:28Z`, and the same-name Certificate is generation/observed-generation 1 and `Ready=True`.
  Source confirms deploy creates the namespace and converges exact GET/PATCH access before selected-
  Agent restore, while delete calls Authority without a namespace observation or access convergence.
  Correct delete to consume a closed exact-name namespace observation: exact absence proves no
  namespaced Secret or Certificate can exist and emits the existing explicit nothing-to-retain
  outcome; exact presence converges only the already-declared Role, RoleBinding, and API-egress
  policy before Authority retention. Failed/malformed/mismatched observation or access still
  refuses. Never reinterpret `TlsTargetSecretUnavailable` as absence, broaden RBAC, inspect Secret
  data, or bypass Authority. `TLS-RETAIN-PUBLIC-EDGE-SECRET-UNAVAILABLE-2026-09-05` stays open until
  the corrected live `pre-1` crosses it.
- The correction is code-local complete. The new closed namespace classifier accepts only
  exit-zero empty output or exact `v1`/`Namespace`/requested-name JSON and refuses subprocess,
  decode, kind/version, and identity failures. Namespace absence emits the existing explicit
  nothing-to-retain result without access mutation or Agent contact; presence applies only the
  existing three exact access objects before the unchanged Authority workflow, whose
  `secret-unavailable` result remains terminal. Focused pure and installed CLI regressions pass
  **1/1** each; the latter proves present delete adds exactly those three objects and absent retry
  adds none. Full unit validation passes primary **4841/4841** plus auxiliaries **27/27**,
  **35/35**, and **36/36**; installed `clean-room-handoff`, canonical `prodbox dev check`, docs lint,
  and diff check pass. Gate-built and installed binaries are exact at
  `sha256:b12bacc4809f404855ccf388b19325131eee0f098d6c3189670dda4a3b2f3e35`. Rerun exact live
  `pre-1`; the named TLS counterexample, independent Gateway-DNS refusal, later qualification
  proofs, and legacy-writer cutover remain open until live evidence crosses them.
- The corrected live `pre-1` crosses and live-closes
  `TLS-RETAIN-PUBLIC-EDGE-SECRET-UNAVAILABLE-2026-09-05` and the code-locally corrected
  `AWS-QUALIFICATION-REGISTERED-STACK-GENERATION-SCOPE-MISSING-2026-09-04`. It runs runtime
  image `sha256:d328b1a6d5d4a3fe1fa4252ad9fe3ae50b00b530a964eab0a66db2a80fe0a51a`, registry
  manifest `sha256:03593f2aa9662215b873f2799e894c44060f5096b6c0599c5c25028349ab1c4d`, and OCI
  import manifest `sha256:5baf6285ead64322c7455f78e04b3eab7b6da360a4899f2ba357b49753c3f244`.
  VS Code retain-before-delete emits the exact Authority/TLS Retention Adapter receipt, the total
  delete/reconcile program completes, and the restored home edge reports Route 53 in sync, accepted
  Gateway/listeners/routes, a current certificate, private-edge readiness, and
  `ready-for-external-proof`; retain-on-ready repeats the exact receipt. Registered stack creation
  then commits (`AwsStackCreationCommitCreated`) and reaches execution under its committed Provider
  scope, proving the missing-scope fix live. Its admitted create terminates at
  `AuthorityProviderTransportFailed (AuthenticatedClientTransportFailed
  (ControlPlaneTransportFailed (HttpTimeout "response timeout")))`. Stable counterexample
  `AWS-QUALIFICATION-REGISTERED-STACK-CREATE-PROVIDER-DISPATCH-TIMEOUT-2026-09-05` owns this
  exact Authority-to-Provider execution/response boundary. A stack may exist under that committed
  cycle; exact terminal cleanup is unproved and operational credentials are preserved. Do not infer
  effect absence, start a successor cycle, or change timeout/replay/recovery/cleanup before reading
  only the licensed Provider/Authority evidence and exact non-secret registered generation/resource
  observations. No qualification artifact or activation witness exists, no preactivation cycle has
  passed, and the legacy public writer remains sole.
- Licensed post-terminal logs add no hidden execution cause: Target Agent reports only the
  unrelated completed AWS-admin preparation, and Lifecycle Authority emits no additional line.
  Source proves a response-budget composition defect. The Authority's in-cluster Provider client
  already uses the typed 330-second budget containing the admitted 300-second child schedule plus
  30 seconds of protocol overhead, while every host `ProviderCaller` execution reaches Authority
  through the generic 30-second client. The outer request can therefore time out while the committed
  inner operation is still validly executing, and that timeout proves neither effect presence nor
  absence. Correct only the Provider-route outer transport to consume the same typed 330-second
  constant for execute and admit-and-execute calls. Keep admission-only and unrelated Authority
  routes on the generic budget, and preserve the exact submission key, operation, digest, intent,
  authentication, child deadline, durable generation, and replay semantics.
- The route-specific correction is code-local complete. `LocalClient` projects the existing typed
  330-second Provider budget onto the outer host-to-Authority client, authentication keeps the same
  caller-bound transport, and `ProviderCaller` selects it at exactly four execute or
  admit-and-execute sites while the one admission-only site retains the generic 30-second client.
  The exact timeout plus mutation-sensitive source-shape regression passes **1/1**. Full unit
  validation passes primary **4841/4841** plus auxiliaries **27/27**, **35/35**, and **36/36**;
  installed `clean-room-handoff` passes its complete fake matrix and canonical `prodbox dev check`
  passes repository policy, pinned Fourmolu, HLint (`No hints`), generated/documentation checks,
  and warning-clean all-target compilation. Gate-built and installed binaries are exact at
  `sha256:2001b22c13f5d280632cb4773bdf77e5f4ab26e1b204960144412bd6fe76929d`. Rerun exact
  live `pre-1` so the existing committed generation is recovered or settled without inventing
  absence or a successor. The Provider-dispatch timeout remains open until that live crossing;
  exact cleanup, qualification evidence, activation, preactivation cycles, and writer cutover stay
  unproved.
- The exact live retry uses local runtime image
  `sha256:c7769241be5ee65274d91be72375feffe0678f07ed6245817fd8a359227ab988`, registry
  manifest `sha256:7d9eba2b5145e9bf928e54ebbacb2c3c5ae2b17005f609cbc8f9f0cb8ebab98a`, and OCI
  import manifest `sha256:10cd8dcab6e9d33c66946a2f771895ada22f2cc3b2d4bdc4283431e89f1b8255`.
  It revalidates the exact VS Code Authority/TLS Retention Adapter receipt, and the total restore
  report proves all four deletes, Gateway MinIO bootstrap, and all four reconciles succeeded. The
  final public-edge wait then reselects independent existing counterexample
  `HOME-PUBLIC-EDGE-GATEWAY-DNS-WRITE-AUTHORITY-NOT-READY-2026-09-04`: the requested DNS record
  binding is observed but its write authority is not ready. Registered stack execution is not
  reached, so the Provider outer-budget correction stays code-locally green but not live-closed.
  Exact terminal cleanup is unproved and operational credentials remain preserved. Diagnose only
  from the licensed Target-Agent/Authority logs and non-secret Gateway-DNS ownership/status
  observations; do not change Provider behavior or start a successor cycle. No artifact,
  activation witness, or preactivation cycle exists, and the legacy public writer remains sole.
- Source-local and exact live-status diagnosis selects nested stable counterexample
  `PUBLIC-EDGE-WAIT-TRANSIENT-GATEWAY-DNS-EXIT-2026-09-05`. With no intervening mutation or
  restart, the same home Gateway endpoint later reports `gateway_owner=node-a`,
  `node_disposition=owner`, `has_active_claim=true`, ready continuity at epoch 1 / sequence 26250,
  `can_write_dns=true`, and last DNS write `70.54.80.113`; the unchanged installed `edge status`
  then reports `CLASSIFICATION=ready-for-external-proof`. This proves transient post-restore
  authority convergence rather than a persistent credential, claim, continuity, or record defect.
  Both public-edge waiters have a 60-attempt, ten-second convergence envelope but abort on every
  nonzero `edge status`; the exact Gateway-DNS not-ready observation is rendered as nonzero, so the
  remaining budget is never consumed. Add a single typed subprocess-observation classifier shared
  by both waiters: retry the exact fixed Gateway-DNS authority-not-ready diagnostic, complete only
  on the ready classification, continue waiting on successful non-ready classifications, and keep
  every unrelated nonzero terminal. Its stable fake reproducer proves transient-failure-then-ready
  succeeds while an unrelated failure stays closed, holding the command, topology, attempt budget,
  and output constant. Preserve Gateway credentials, election, continuity, DNS mutation/read-back,
  Provider behavior, and the existing attempt/deadline envelope; validate locally before the same
  `pre-1`. Exact cleanup, Provider live crossing, qualification evidence, activation,
  preactivation cycles, and writer cutover remain unproved.
- The transient public-edge wait correction is code-local complete. `Prodbox.PublicEdge` owns one
  closed `PublicEdgeReadinessObservation` classifier plus the two exact output tokens, and both the
  canonical `TestRunner` prerequisite and direct `TestValidation` wait consume it. Only an exact
  diagnostic line for home Gateway-DNS authority convergence turns a nonzero result into pending;
  ready completes, successful non-ready remains pending, and every unrelated nonzero remains
  terminal. The 60-attempt / ten-second envelope, certificate repair budget, Gateway election,
  claim, continuity, credential, DNS effect/read-back, and Provider behavior are unchanged. The
  focused transient-failure-then-ready and unrelated-failure reproducer passes **1/1**. Full unit
  validation passes primary **4842/4842** plus auxiliaries **27/27**, **35/35**, and **36/36**;
  installed `clean-room-handoff` passes the complete success/effect-failure/cancellation/
  response-loss/restart fake matrix. Documentation lint and diff hygiene pass, and canonical
  `prodbox dev check` passes repository policy, pinned Fourmolu, HLint (`No hints`), generated/docs
  checks, and warning-clean all-target compilation. Gate-built and installed executables are exact
  at `sha256:d9704bec92880a13da5c32ec4b18c21f35fb30fe560c157df94f49f9c9044e37`. Rerun the same live
  `pre-1` so post-restore Gateway authority can spend this bounded convergence budget before the
  already committed registered stack generation is recovered or settled. The broader Gateway-DNS
  and Provider-dispatch counterexamples remain open until that live crossing; exact cleanup,
  qualification evidence, activation, preactivation cycles, and writer cutover remain unproved.
- The exact live `pre-1` uses local runtime image
  `sha256:b6389d8bdd375f88effbe5d167fe901ccaa976bdb20dca6bc4e8882964d9947a`, registry manifest
  `sha256:61f8943c0cc77e980b1f84310aee2cf71fbf8fbb09696ea8a9d5f0d2078bc0d5`, and OCI import
  manifest `sha256:c9856ab84e1f76c4cdcac7bb85b8f6ea9a07227f151ea574073ef56097c1f6eb`.
  It preserves the exact Vault root/session/storage identity, observes the Authority/TLS Retention
  Adapter receipt, completes all four deletes/restores, and reaches
  `CLASSIFICATION=ready-for-external-proof` with home DNS in sync. This live-closes
  `HOME-PUBLIC-EDGE-GATEWAY-DNS-WRITE-AUTHORITY-NOT-READY-2026-09-04`. The already committed
  `AwsStackCreationCommitCreated` generation then executes and returns through the corrected
  Provider outer budget, live-closing
  `AWS-QUALIFICATION-REGISTERED-STACK-CREATE-PROVIDER-DISPATCH-TIMEOUT-2026-09-05`. Its typed 503
  selects stable counterexample
  `PROVIDER-WORKER-PULUMI-YAML-LANGUAGE-PLUGIN-MISSING-2026-09-05`: exact
  `ProviderIntentExecutionObservationUnavailable` reports that Pulumi cannot load
  `pulumi-language-yaml` from the Provider workspace or `PATH` while previewing
  `aws-eks-subzone`. A stack may exist under the cycle, exact cleanup is unproved, and operational
  credentials remain preserved. Read only the licensed Target-Agent/Authority logs, then diagnose
  Provider image/workspace/plugin discovery from source and non-secret packaging observations
  before changing packaging or execution behavior; do not invent effect absence or a successor
  generation. No qualification artifact, activation witness, or preactivation cycle exists, and
  the legacy public writer remains sole.
- The licensed logs add no hidden worker failure: Target Agent contains only the unrelated
  completed AWS-admin preparation and Lifecycle Authority is silent. Provider source fixes the
  workspace at `/opt/build/pulumi/aws-eks-subzone`, the executable at `/usr/local/bin/pulumi`, and
  plugin discovery to the image's inherited `PATH`. The exact native-architecture Pulumi `3.228.0`
  archive contains both `pulumi` and `pulumi-language-yaml`; the Dockerfile installs only the CLI,
  deletes the extraction, and the exact failed image consequently contains no YAML language host.
  This closes the cause to union-runtime packaging. Install only that exact bundled language host
  beside the CLI from the same pinned archive and enforce the source packaging contract. Do not
  widen plugin discovery, use the ambient host plugin, change Pulumi/program/Provider behavior,
  invent effect absence, or allocate a successor generation. The counterexample remains open until
  local validation and unchanged live `pre-1` cross it; exact cleanup, qualification evidence,
  activation, preactivation cycles, and writer cutover remain unproved.
- The narrow packaging correction is code-local complete. The one pinned Pulumi extraction now
  installs exactly its CLI and matching YAML language host beside each other under `/usr/local/bin`
  before deletion; the source contract also forbids a plugin-install command and ambient host
  plugin path. Focused Dockerfile proof passes **1/1**, the unit target is warning-clean, and the
  full unit matrix passes primary **4842/4842** plus auxiliaries **27/27**, **35/35**, and
  **36/36**. Installed `clean-room-handoff` passes the complete success/effect-failure/
  cancellation/response-loss/restart fake matrix. Canonical `prodbox dev check` passes repository
  policy, pinned Fourmolu, HLint (`No hints`), generated/docs checks, and warning-clean all-target
  compilation; diff hygiene passes. The gate-built and installed executable remains exact at
  `sha256:d9704bec92880a13da5c32ec4b18c21f35fb30fe560c157df94f49f9c9044e37`, as expected because
  only container packaging, its test contract, and docs changed. Rerun the exact live `pre-1` to
  build and deploy the corrected image and recover or settle the existing committed generation.
  The counterexample, exact cleanup, qualification evidence, activation, preactivation cycles, and
  writer cutover remain open until that crossing.
- The unchanged live `pre-1` builds corrected local runtime image
  `sha256:9240b03160b232e2533b536a9ee11cda9de026a4124579b4e8fda7ffdedb91ce` in 1,140.7 seconds,
  with both pinned Pulumi binaries visible in the emitted layer; it publishes registry manifest
  `sha256:1bcb5c6f5d5d6506baeb2cd798dadad1f92293431e681c4aa0b071673021967f`, imports OCI manifest
  `sha256:03148c82acb648d66b5abf096e04497e541d4eeda55480424bcdd9c099582d69` in 198.6 seconds, and
  deletes only superseded local image `sha256:b6389d8bdd375f88effbe5d167fe901ccaa976bdb20dca6bc4e8882964d9947a`.
  Before candidate/Provider execution, prerequisite reconcile terminates at exact `Vault bootstrap
  failed: wait for Bootstrap Broker Deployment rollout: kubectl rollout status exited 1: error:
  timed out waiting for the condition`. Stable counterexample
  `BOOTSTRAP-BROKER-ROLLOUT-TIMEOUT-AFTER-RUNTIME-IMAGE-2026-09-05` owns this boundary. Packaging is
  built but the Pulumi-language-host counterexample is not live-closed. Use only the licensed
  Target-Agent/Authority logs plus non-secret Bootstrap Broker object/status/event observations;
  change no Bootstrap, Pulumi, Provider, generation, or timeout behavior before selecting the
  cause. The already committed generation remains the only licensed one, exact cleanup remains
  unproved, and preserved operational credentials remain required for recovery. No qualification
  artifact, activation witness, or preactivation cycle exists, and the legacy public writer remains
  sole.
- The licensed Target-Agent/Authority logs contain no related worker failure. Non-secret object and
  event evidence selects the rollout cause exactly: Bootstrap Broker revision 206 created Pod
  `bootstrap-broker-b6c946cff-l26n4` at 13:43:56Z on the corrected image while the sole Ready node
  carried `node.kubernetes.io/disk-pressure:NoSchedule`, and scheduling refused only for that
  untolerated taint. The kubelet cleared `DiskPressure` and the taint at 13:48:56Z, scheduled that
  same Pod immediately, and made it Ready at 13:49:03Z with zero restarts and image ID
  `sha256:9240b03160b232e2533b536a9ee11cda9de026a4124579b4e8fda7ffdedb91ce`; the one-minute
  Broker transport barrier had already terminated the command. This is not a Bootstrap crash and
  does not license a timeout widening. Stable nested counterexample
  `REGISTRY-RUNTIME-UNTAGGED-MANIFEST-RETENTION-DISK-PRESSURE-2026-09-05` selects the retained
  storage defect. The runtime repository has 177 manifest revisions behind only `latest` and the
  machine tag, both resolving to current manifest
  `sha256:1bcb5c6f5d5d6506baeb2cd798dadad1f92293431e681c4aa0b071673021967f`. A read-only
  registry-API/revision fold measures 929 unique descriptors / 53,016,418,359 bytes across the
  history, 14 / 942,074,855 bytes in the current manifest, and therefore 915 historical-only
  descriptors / 52,074,343,504 bytes, matching the measured 52 GiB registry blob store. The
  supported path bounds only host-Docker dangling images; it has no registry garbage-collection
  owner, so moving-tag pushes retain every old runtime manifest and unique layer. Add a narrow,
  typed registry-retention reconcile before retrying: observe read-only mode, run the registry's
  own `garbage-collect --delete-untagged` against the same mounted typed S3 config/credential
  projection, restore and observe read-write service, and prove all current tags/digests unchanged.
  It must recover on interruption, fail closed, retain every currently tagged manifest in every
  repository, and never delete Docker/build-cache, containerd, raw MinIO objects, Secrets, or the
  retained root. Freeze the measured 177-revision/two-current-tag shape in a repository-owned fake
  reproducer before the first live cleanup. No direct cleanup or behavior change has run yet. The
  Pulumi-language-host counterexample, committed generation, exact cleanup, qualification evidence,
  activation, preactivation cycles, and writer cutover remain open.
- The narrow retained-registry correction is code-local complete. `Prodbox.Registry.Retention`
  owns the closed catalog/tag/concrete-manifest observation and exact reference read-back; the
  retained-home RKE2 reconcile applies one access-mode-indexed Registry
  ConfigMap/Deployment/Service, observes the exact read-only rollout, invokes only Distribution's
  mounted-config collector, restores and observes the read-write rollout on ordinary failure or
  interruption, then proves the unchanged complete reference snapshot and a fresh
  Registry-to-MinIO write edge before the custom-image build. The repository fake freezes 177
  revisions behind two tags and observes **177 -> 1** without admitting raw storage,
  Docker/build-cache, containerd, Secret, or retained-root deletion. Focused retention tests pass
  **4/4**; the installed RKE2 reconcile/delete fake passes **1/1**; the full unit matrix passes
  primary **4846/4846** plus auxiliaries **27/27**, **35/35**, and **36/36**; installed
  `clean-room-handoff` passes; installed `cli` and `env` each pass **64/64**; documentation lint,
  diff hygiene, warning-clean unit/integration builds, and canonical `prodbox dev check` all pass.
  The gate-built and installed executable are byte-identical at
  `sha256:d82973f86e3fd6e4aaba6c040f4bdf3dd48a015b968741aacb97ee52680e4b8d`. Rerun the
  same exact live `pre-1`; its supported retained-home reconcile must reclaim only untagged
  history, read back the existing current tags unchanged and restored read-write service, recover
  the Bootstrap Broker scheduling boundary with sufficient disk headroom, and then cross the
  still-open Pulumi-language-host counterexample against the already committed generation. No
  direct cleanup has run, and exact cleanup, qualification evidence, activation, preactivation
  cycles, and writer cutover remain open.
- The unchanged live `pre-1` runs from 11:36:54 to 12:28:36 EDT and exposes stable counterexample
  `REGISTRY-GC-UNKNOWN-QUIET-FALSE-SUCCESS-2026-09-05` before the first live collection. On each
  of three retained-home reconcile passes the deployed `registry:2` CLI prints exact `Error:
  unknown flag: --quiet` / `Run 'registry help' for usage.`, but `kubectl exec` is accepted as
  success; the program restores and observes the read-write rollout, emits the false `untagged
  collection completed` narration, and continues into image publication. Exact postflight
  contradicts that narration: the retained Registry store remains **52 GiB** and the runtime
  revision inventory grows from **177 to 178**, while both current tags correctly advance to
  registry manifest
  `sha256:70eb7c9b8d91067693d9f4f6f2a264abc2787f32d577f542e4332bb671e9baca`; Registry generation
  9 is Available in explicit `read-write` mode and the Ready node remains pressure/taint-free. The
  current interpreter trusts process exit plus unchanged tagged references, neither of which
  proves the collector ran. Correct only this boundary: remove the unsupported `--quiet`, capture
  the exact collector result, refuse an exit-zero nonempty stderr/usage rejection, preserve
  ordinary and asynchronous read-write restoration, and make the installed fake reproduce
  exit-zero stderr plus no collection/no build before accepting the corrected command. Do not
  delete registry objects directly or widen the already-typed target set. The run nevertheless
  builds local image
  `sha256:d6672a7150f8b9b3e35b1c235cf72bf8e49b4048f320386e33790e5ce747201a`, publishes the exact
  registry manifest above, imports OCI manifest
  `sha256:4ca3113c2d2191119b9270428e884c377a8b2ad2cf5994a1bde0d19f7306e4ce`, crosses the former
  Bootstrap scheduling boundary, and reaches the already committed stack generation; Provider
  dispatch then ends at exact `HttpConnectionFailure "NoResponseDataReceived"`. Exact cleanup is
  not proved, operational credentials are preserved, and no qualification artifact, activation
  witness, preactivation cycle, or writer cutover exists. No direct registry cleanup has run.
- That collector-result counterexample is now code-local closed without broadening the cleanup
  target. The sole command is the pinned Distribution CLI's supported
  `garbage-collect --delete-untagged <mounted-config>` form; its subprocess is bounded to 16 MiB
  stdout, 64 KiB stderr, and 30 minutes. Success requires process success, exactly empty stderr,
  and an exact set match between parsed `repository: marking manifest <canonical-digest>` records
  and the distinct current repository/digest pairs observed before the read-only fence. The
  installed counterexample reproduces exit-zero usage stderr, proves no collection audit and no
  custom-image build, and observes a later read-write manifest after the read-only manifest; its
  paired success case proves the supported command and exact **177 -> 1** audit. The focused pure
  classifier passes **1/1**; the installed refusal and success crossings pass **1/1** each in
  **96.48 s** and **90.33 s**; the warning-clean operator/unit/integration build passes; the full
  unit matrix passes primary **4846/4846** plus auxiliaries **27/27**, **35/35**, and **36/36**;
  installed `clean-room-handoff` and canonical `prodbox dev check` pass; installed `cli` and `env`
  each pass **65/65** in **834.24 s** and **837.61 s**. The gate-built and installed executable
  are byte-identical at
  `sha256:380733901d37416eab91ff0fccf1fcacc0f7207a9331349d1d37dafc1e2edd74`. Rerun the
  same exact live `pre-1`; only that supported crossing may perform the now-validated collection,
  and it must prove current-reference preservation, restored read-write service, and reclaimed
  retained-registry headroom before Provider-capacity diagnosis continues. Exact cleanup,
  qualification evidence, activation, preactivation cycles, and writer cutover remain open.
- The exact corrected live `pre-1` then registers stable counterexample
  `REGISTRY-GC-DELETE-PROGRESS-EXCEEDS-STDERR-64K-2026-09-05`. The supported command reaches the
  real deletion phase, but its ordinary deletion stream exceeds the authored 64 KiB stderr
  ceiling; the bounded subprocess kills/refuses it as `bounded subprocess stderr exceeds its
  configured ceiling`, restores and observes Registry generation 11 in explicit `read-write`
  mode, and stops before custom-image build. Exact postflight proves that this was neither a usage
  rejection nor a pre-effect refusal: the runtime revision inventory fell from **178 to 30**
  before termination, while both current tags still resolve to
  `sha256:70eb7c9b8d91067693d9f4f6f2a264abc2787f32d577f542e4332bb671e9baca`; the retained MinIO
  root still reports **52 GiB**, the host has **42 GiB** free, and the node is Ready with no disk
  pressure or taint. The empty-stderr/64-KiB assumption therefore cannot represent the pinned
  collector's valid progressive deletion protocol, and killing at that observation bound converts
  a valid in-progress mutation into an unclassifiable partial run. Before another live crossing,
  derive the collector's exact stdout/stderr grammar and finite output bound from the installed
  version and the registered reference/revision limits, preserve exit-zero usage rejection as a
  distinct refusal, freeze this **178 -> 30** partial-progress case locally, and prove a complete
  collector result plus unchanged current references without unbounded capture or a direct
  cleanup. No Provider-capacity correction, qualification artifact, activation witness,
  preactivation cycle, or writer cutover has begun.
- That progressive-deletion counterexample is code-local closed by an exact two-pass protocol. A
  read-only probe of the installed Distribution 2.8.3 collector exits 0 with **148,372 bytes** on
  stdout, empty stderr, **23** repository records, **23** current-manifest marks, **269** scoped
  blob marks, **29** eligible manifests, and **1,099** eligible blobs; every one of its **1,445**
  lines matches the now-authored grammar. The retained-home reconcile first runs that command with
  `--dry-run --delete-untagged` under the read-only fence, parses the complete finite evidence,
  and only then runs the deletion form with the same bounds. A command-local
  `REGISTRY_LOG_LEVEL=error` suppresses ordinary deletion telemetry without suppressing stdout
  evidence or accepting usage/error stderr; the delete evidence must exactly replay the dry-run
  evidence before unchanged current references and restored read-write service can be accepted.
  The repository fake freezes both the **178 -> 30** over-ceiling partial mutation caused by the
  old command and the exact two-pass **177 -> 1** result. Focused parser/argument tests pass
  **1/1** each; the fast partial-mutation reproducer passes **1/1** in **0.02 s**; installed
  usage-refusal and two-pass-success crossings pass **1/1** each in **97.07 s** and **90.24 s**;
  the full unit matrix passes primary **4846/4846** plus auxiliaries **27/27**, **35/35**, and
  **36/36**; installed `clean-room-handoff`, canonical `prodbox dev check`, and warning-clean
  compilation pass; installed `cli` and `env` pass **66/66** in **851.97 s** and **833.11 s**. A
  final description-only accuracy correction is warning-clean and its complete plan-renderer group
  passes **39/39**. The gate-built and installed executable are byte-identical at
  `sha256:b14f0d6ee2c9ffb88fca61788b0582835c0296a7d422cb51c691fdc5de36cc45`. Rerun the exact
  supported live `pre-1`; it must prove the collection's exact replay, current-reference
  preservation, restored read-write service, and physical retained-registry headroom before
  Provider-capacity diagnosis continues. Exact cleanup, qualification evidence, activation,
  preactivation cycles, and writer cutover remain open.
- The only permitted post-terminal logs add no Provider detail: Target Agent is empty and Lifecycle
  Authority contains only the earlier completed AWS-admin preparation. Non-secret Kubernetes
  status/events select the Provider terminal exactly and register stable counterexample
  `PROVIDER-WORKER-PULUMI-EPHEMERAL-STORAGE-EVICTION-256MI-2026-09-05`. Pod
  `provider-worker-5b8665b65-z7hqd` starts at 16:07:33Z on registry manifest
  `sha256:70eb7c9b8d91067693d9f4f6f2a264abc2787f32d577f542e4332bb671e9baca`, runs the admitted
  request for 21 minutes, reports readiness 503 at 16:28:29Z, and is killed/evicted at 16:28:36Z
  with exit 143 because `Pod ephemeral local storage usage exceeds the total limit of containers
  256Mi`. The replacement Pod is zero-restart Ready on the same image. This proves the packaged
  YAML host crossing and selects Provider Pulumi workspace/output storage capacity—not transport,
  memory, Registry pressure, generation allocation, or AWS-stack semantics—as the cause of
  `NoResponseDataReceived`. Before changing the typed Provider resource envelope, measure the
  exact workspace/output paths and a production-run peak, freeze the 256 Mi eviction in the
  constant-total resource counterexample, and justify/repartition the replacement envelope without
  widening CPU, memory, persistence, request concurrency, Provider capability, or the registered
  generation. Both registered Registry-collector counterexamples are code-local closed; the
  unchanged live rerun below proves actual retained-registry headroom before this Provider
  correction begins. The stack may exist, exact cleanup remains unproved, and the legacy public
  writer remains sole.
- That exact supported live `pre-1` runs from 14:43:02 to 15:34:21 EDT and live-closes both Registry
  counterexamples. Its first two-pass collection takes the retained MinIO store from **52 GiB** to
  **2.9 GiB**, runtime revisions from **30 to 1**, and host free space from **43 GiB** to **89 GiB**;
  it restores explicit read-write service and reads both current tags back unchanged at
  `sha256:70eb7c9b8d91067693d9f4f6f2a264abc2787f32d577f542e4332bb671e9baca` before image
  publication. Both later retained-home passes accept the same exact two-pass protocol. The run
  builds local image
  `sha256:ea0187255bc28b1a04229c0b6055b68335036939226a7539eead98aff6bd144d` in **1,159.8 s**,
  publishes Registry manifest
  `sha256:3e11d971c440f04291e346e07dbe355f034ad911f8be4718586b53568f4cb157`, imports OCI
  manifest `sha256:1585369769188dcd671e84c27243405a3d43e5c11f83a538bccfce99a0ed6b25` in
  **122.7 s**, and deletes only superseded local image
  `sha256:d6672a7150f8b9b3e35b1c235cf72bf8e49b4048f320386e33790e5ce747201a`. Exact
  postflight retains one runtime revision in a **3.0 GiB** store, **90 GiB** host headroom, Registry
  generation 17 in read-write mode, and both tags on the new manifest. Candidate Provider Pod
  `provider-worker-8455b76c5-7dmmn` is created on that exact manifest, starts at 19:13:59Z, reports
  readiness 503 at 19:34:15Z, and is evicted at 19:34:21Z with exit 143 because total container
  ephemeral use exceeds the unchanged **256 MiB** limit; its replacement is exact-image,
  zero-restart Ready. This independently reproduces
  `PROVIDER-WORKER-PULUMI-EPHEMERAL-STORAGE-EVICTION-256MI-2026-09-05` after eliminating Registry
  pressure: the baseline writable layer is **69,632 bytes**, `/root/.pulumi` is initially absent,
  `/dev/shm` is empty, and the immutable `/opt/build/pulumi` programs occupy **84 KiB**. CRI removes
  the failed snapshot before postflight, so the exact production peak/path remains unobserved. Make
  no capacity or execution change yet: rerun the same supported command with continuous read-only
  sampling of `/root/.pulumi`, `/dev/shm`, `/tmp`, and kubelet rootfs/log usage, then freeze that
  measured peak and the constant-total **256 MiB** counterexample before the correction. The stack
  may exist, operational credentials remain preserved, exact cleanup is unproved, and no
  qualification, activation, preactivation, or writer-cutover evidence exists.
- The unchanged measurement `pre-1` runs from 15:37:56 to 16:03:52 EDT with a one-second read-only
  Provider sampler and closes the missing production path/peak evidence for the same counterexample.
  The replacement Pod begins at **69,632 bytes** of writable rootfs with no `/root/.pulumi`, empty
  `/dev/shm`, and **12 KiB** under `/tmp`. At 16:03:35 kubelet first reports **79,736,832 bytes**
  while `/tmp` already measures **117,344 KiB**. At 16:03:45 kubelet reports the observed peak of
  **337,674,240 bytes**; an exact path fold at 16:03:50 finds **200,804 KiB** under `/tmp`, of which
  **200,792 KiB** is the single `/tmp/pulumi-plugin-tar384574685` download, plus **231,264 KiB**
  under `/root/.pulumi`, of which **231,244 KiB** is the simultaneously extracted
  `plugins/resource-aws-v7.44.0` and **231,216 KiB** is its provider binary. Authority checkpoint
  scratch remains **12 KiB** in `/dev/shm`, including a **4 KiB** stack JSON; application logs are
  only **24,576 bytes**. The Pod reports readiness 503 at 20:03:48Z and is killed/evicted at
  20:03:52Z under the unchanged 256 MiB limit; its exact-image replacement is zero-restart Ready.
  Thus the production cause is the Pulumi AWS-provider download/archive plus extracted-plugin
  transitional overlap, not checkpoint/output state, project content, logs, Registry pressure, or
  application memory. Freeze those exact old-path figures in the repository counterexample.
  Correct packaging so the exact compiled AWS provider is immutable image content and runtime
  discovery writes neither the archive nor provider binary; keep the Provider request/limit at
  **256 MiB** and keep total CPU, memory, ephemeral, persistence, topology, concurrency,
  capability, deadlines, and the registered generation unchanged. The stack may exist, operational
  credentials remain preserved, exact cleanup is unproved, and no qualification, activation,
  preactivation, or writer-cutover evidence exists.
- That Provider-capacity counterexample is now code-local closed without changing an envelope.
  `Prodbox.Capacity.ProviderWorkerBudget` freezes the exact counterexample identity, one fenced
  Worker with one serialized child, one registered-stack reconcile, no injected fault, the measured
  path facts, and an exact old-to-new mapping of `100m / 176Mi / 256Mi / 0 durable` to itself. Its
  superseded disposition is the observed **337,674,240-byte** peak exceeding the
  **268,435,456-byte** limit; its replacement disposition requires both runtime provider-archive
  and provider-binary writes to be zero. Mutation cases refuse a non-failing old peak, envelope
  drift, and either returning runtime write. The union image pins Pulumi AWS provider **7.44.0**,
  verifies the official release SHA-256 for each supported architecture, installs the provider into
  the immutable `/root/.pulumi/plugins/resource-aws-v7.44.0` image path, and confirms its executable.
  All four Pulumi projects declare `aws@7.44.0`, so the runtime cannot select another provider
  version. An isolated exact-checksum installation probe reports resource provider `aws` version
  `7.44.0`; all four project files parse under pinned Pulumi `3.228.0`; Docker's static build check
  reports no warnings. The focused frozen-profile, mutation, and image/package-contract cases pass
  **1/1** each. The full unit matrix passes primary **4848/4848** plus auxiliaries **27/27**,
  **35/35**, and **36/36**; installed `clean-room-handoff` passes; installed `cli` and `env` each
  pass **66/66** in **836.97 s** and **828.93 s**. Repository Haskell/docs lint, docs check, diff
  check, warning-clean all-target compilation, and canonical `prodbox dev check` pass with HLint
  `No hints`. The gate-built and installed executable are byte-identical at
  `sha256:af56a7d532e7fb2c594a54210b89d72afca9d4e6312af89d9e4f2b20bac4c00d`. Rerun exact supported
  live `pre-1` with the same read-only Provider sampler; it must prove no runtime provider archive
  or binary write, no Provider eviction/restart, the unchanged rendered envelope, and successful
  exact Provider completion before qualification work continues. The stack may exist, operational
  credentials remain preserved, exact cleanup is unproved, and no qualification, activation,
  preactivation, or writer-cutover evidence exists.
- The corrected exact `pre-1` rerun closes the ephemeral-storage barrier and exposes a distinct
  runtime-memory counterexample. It builds local image
  `sha256:a3157208125f70547bc4a47f7a733ec421afda2c1989726902992b3d457721a3` in **1169.8 s**, publishes
  registry manifest
  `sha256:2dc12d0bc7f39fc78ba17c1b67bd987d48aa8578336365af66e1668db0bcd07a`, imports OCI manifest
  `sha256:63e43f8bef0147cca95776f006254ee057d178720035666c38edf85ece032b53` in **214.2 s**, and removes
  only the superseded local runtime image. Provider Worker generation 37 runs that exact image at
  the unchanged `100m / 176Mi / 256Mi / 0 durable` envelope, remains Ready with zero restarts, and
  exposes the exact **989,311,138-byte** AWS provider from immutable image content. Across **3,214**
  read-only samples its writable-root peak is only **167,936 bytes**, logs peak at **24,576 bytes**,
  `/tmp` remains **12 KiB**, checkpoint scratch peaks at **12 KiB**, and the runtime provider archive
  remains exactly zero. Pulumi therefore reaches schema loading without the former
  download/extraction overlap, but the provider subprocess exits and three resource-type
  resolutions report `rpc error: code = Unavailable ... EOF`; the Provider returns
  `ProviderIntentExecutionObservationUnavailable` and the Authority returns 503. The still-running
  zero-restart daemon's cgroup supplies the cause: `memory.peak` equals `memory.max` at exactly
  **184,549,376 bytes** with `oom_kill 6` and `max 83`. Stable counterexample
  `PROVIDER-WORKER-PACKAGED-AWS-SCHEMA-OOM-176MIB-2026-09-05` freezes this one-fenced-worker,
  one-serialized-child, one-registered-stack reconcile with no injected fault before any memory or
  execution change. An isolated, non-mutating preview of the same project and exact image against a
  fresh local file backend and deliberately invalid AWS credentials loads the packaged schema and
  reaches only `Invalid credentials configured`: uncapped `memory.peak` is exactly
  **1,024,434,176 bytes** (**976.9765625 MiB**) with zero OOM events. The derived production
  envelope reserves that measured child as **1,024 MiB** plus the existing **96 MiB**
  daemon/kernel/safety decomposition, for **1,120 MiB** total. Repeating the probe at a hard
  **1,120 MiB** cgroup limit again reaches only the invalid-credential boundary with `memory.peak`
  **966,365,184 bytes** and zero OOM events. The compiled plan is **7,000m / 13,312Mi / 80,032Mi /
  177,952Mi** allocatable versus **6,210m / 9,040Mi / 15,456Mi / 155,648Mi** currently drawn,
  leaving exact idle headroom **790m / 4,272Mi / 64,576Mi / 22,304Mi**. Close the counterexample
  through the typed capacity owner by transferring **944 MiB** of that already-declared memory
  headroom to Provider Worker: the exact mapping is old Provider `100m / 176Mi / 256Mi / 0` plus
  idle `790m / 4,272Mi / 64,576Mi / 22,304Mi` to new Provider `100m / 1,120Mi / 256Mi / 0` plus
  idle `790m / 3,328Mi / 64,576Mi / 22,304Mi`. It holds the topology-normalized **890m / 4,448Mi /
  64,832Mi / 22,304Mi** mapped total and the complete host allocatable total constant; every
  non-Provider workload, background load, topology, concurrency, capability, deadline, fault
  schedule, and registered generation remains unchanged. Do not reopen the now-proven
  immutable-provider packaging behavior. The stack may exist, operational credentials remain
  preserved, exact cleanup is unproved, and no qualification, activation, preactivation, or
  writer-cutover evidence exists.
- The schema-memory correction is code-local complete while its live replacement observation
  remains explicitly pending. `ProviderWorkerBudget` owns the stable frozen failure, exact
  non-mutating sizing observations, unchanged causal profile, full allocatable/background vectors,
  and the old Provider plus idle-headroom → new Provider plus idle-headroom mapping. Its validator
  reports `ProviderWorkerSchemaMemoryPendingLiveReplacement`; it cannot report closure without an
  exact live Provider completion at the new envelope with zero OOM and daemon restarts. The
  capacity plan now uses one **1,024 MiB** serialized child slot and derives the exact **1,120 MiB**
  request-equals-limit Provider envelope while retaining its **64 MiB** GHC heap cap, 300-second
  child deadline, physical one-child permit, unchanged CPU/ephemeral/durable resources, all other
  workload envelopes, and host capacity. The compiled replacement draw is exactly **6,210m /
  9,984Mi / 15,456Mi / 155,648Mi** inside unchanged allocatable **7,000m / 13,312Mi / 80,032Mi /
  177,952Mi**. Focused frozen-mapping, runtime-memory, and chart-render cases pass **1/1** each; the
  full unit matrix passes primary **4849/4849** plus auxiliaries **27/27**, **35/35**, and
  **36/36**. Warning-clean all-target compilation, canonical `prodbox dev check` with HLint `No
  hints`, installed `clean-room-handoff`, installed `cli` **66/66** in **836.54 s**, installed `env`
  **66/66** in **826.02 s**, documentation, and diff gates pass. The gate-built and installed
  executable are byte-identical at
  `sha256:6eb91fa7bfe368e1abe534af8c61a4bf2614318224052a06117340148ce08c31`. Rerun the exact
  supported live `pre-1` with the same read-only Provider sampler. It must read back the exact
  `100m / 1120Mi / 256Mi / 0 durable` envelope, zero runtime provider writes, zero OOM/restarts, and
  successful exact Provider completion before the typed live observation or qualification state
  can close. The stack may exist, operational credentials remain preserved, exact cleanup is
  unproved, and no qualification, activation, preactivation, or writer-cutover evidence exists.
- The exact corrected live `pre-1` advances through retained-home reconciliation and the candidate
  body, then exposes stable counterexample
  `PROVIDER-WORKER-PULUMI-STACK-CONFIG-ABSENT-2026-09-05` at the first admitted
  `aws-eks-subzone` create. The run builds local image
  `sha256:a75c142a8ee326951104d5c081d56533ed918bd48a00e04dce432cf1d886cd7e` in **1,148.6 s**,
  publishes Registry manifest
  `sha256:6524677526cc282c4313b1f859bf7b9884e55d260e96c1a385d09f71316ad93b`, imports OCI
  manifest `sha256:af8c04be12992de5f22f1e3ac6d9e0564720c0438c94665815143eaed166aaf3b`, and removes
  only the superseded Registry/local runtime revision. Provider Worker generation 38 runs that
  exact image at `100m / 1,120Mi / 256Mi / 0 durable`, remains Ready with zero restarts, and across
  **484** read-only samples (**482** complete filesystem/cgroup observations) peaks at exactly
  **933,298,176 bytes** below `memory.max` **1,174,405,120 bytes**, with cgroup `max 0`, `oom 0`,
  and `oom_kill 0`. Writable rootfs peaks at **51,101,696 bytes**, logs at **24,576 bytes**, `/tmp`
  and checkpoint scratch at **12 KiB** each, and the runtime provider archive remains zero; the
  immutable AWS provider remains exact at **989,311,138 bytes**. This proves the replacement crosses
  packaged schema loading without the prior OOM, but it does not satisfy the typed memory
  counterexample's successful-completion condition. The committed stack lifecycle generation
  reaches its fenced Provider execution and returns `ProviderIntentExecutionObservationUnavailable`:
  Pulumi reports missing required configuration variables `parentZoneId` and `subzoneName`, followed
  by config and `awsProvider` registration failures. The source trace locates the loss after typed
  intent decoding: `compiledStackFor` retains both inputs, but `observePulumiStack` invokes the
  mandatory read-only preview without `compiledStackConfiguration`; only the later apply arm calls
  `setPulumiConfiguration`, and observe-first refusal prevents that arm from running. A fresh Worker
  image therefore cannot observe an Authority-retained checkpoint whose image-local Pulumi stack
  config file is absent. Freeze the superseded empty preview projection and the exact replacement
  arguments under the unchanged topology/resource profile, make the production preview consume
  that projection, and prove mutations of either key fail the reproducer before another live rerun.
  The stack may exist, operational credentials remain preserved because exact cleanup was not
  proved, and no qualification, activation, preactivation, or writer-cutover evidence exists.
- The missing-stack-config counterexample is code-local closed under the unchanged production
  profile. `Prodbox.ControlPlane.ProviderPulumiConfigProjection` freezes its stable identity, the
  one-fenced-worker/one-serialized-child/one-registered-stack/no-fault causal profile, exact
  `100m / 1,120Mi / 256Mi / 0 durable` old-to-new envelope, both observed missing keys, the
  superseded config-free preview argv, and the replacement's two direct `--config key=value`
  arguments. Production `observePulumiStack` consumes that same pure argument projection, while the
  apply arm and every other Provider boundary remain unchanged. Removing either key, restoring the
  superseded preview, or changing the resource mapping fails the reproducer. Focused regressions
  pass **2/2**; the complete unit matrix passes primary **4,851/4,851** plus auxiliaries **27/27**,
  **35/35**, and **36/36**. Warning-clean all-target compilation, canonical `prodbox dev check` with
  HLint `No hints`, installed `clean-room-handoff`, installed `cli` **66/66** in **843.59 s**,
  installed `env` **66/66** in **830.41 s**, documentation, and diff gates pass. The gate-built and
  installed executable is exact at
  `sha256:27c686aa7a0fede6c5179b0da2b2596d5d4953278b8fde240e3d88628681a420`. Rerun exact live
  `pre-1` with the Provider sampler. Crossing configured observe-first preview into the exact AWS
  action closes this config-specific replacement result even if a later independent boundary fails;
  the typed schema-memory replacement observation separately requires successful Provider
  completion with zero OOM/restarts. Exact cleanup, qualification, activation, preactivation, and
  writer cutover remain unproved.
- That exact live `pre-1` closes the missing-stack-config counterexample and exposes distinct stable
  counterexample `LIFECYCLE-PROVIDER-ROUTE53-HOSTED-ZONE-CREATE-DENIED-2026-09-05`. The run starts
  sampling at 22:33:59 EDT, builds local image
  `sha256:e132d4825c5adf98a7250c02156b8cc174c2a3648f75767f2d0a0e112aec245a` in **1,155.4 s**,
  publishes Registry manifest
  `sha256:43df78272eade476fead42dcd67ae86543dbffe3b6d3c23544d4cbd8afcaf9b9`, imports OCI
  manifest `sha256:7bdaff97f1ca1e731cdd266d6263bd624e6c8d39aba3a2f366a05a392f08ac4d` in
  **135.0 s**, and removes only the superseded Registry/local runtime revision. Provider Worker
  generation 39 Pod `provider-worker-796668c5bd-9p7j7`, UID
  `202232df-6803-4a10-99a5-bc3af1884237`, runs that exact local image at
  `100m / 1,120Mi / 256Mi / 0 durable` and remains Ready with zero restarts. Across **496** samples
  (**493** complete filesystem/cgroup observations), its exact `memory.peak` is **1,127,190,528
  bytes** below `memory.max` **1,174,405,120 bytes**, with cgroup `max 0`, `oom 0`, and `oom_kill 0`;
  writable rootfs peaks at **51,101,696 bytes**, logs at **24,576 bytes**, working set at
  **778,256,384 bytes**, `/tmp` at **12 KiB**, checkpoint scratch at **84 KiB**, and the runtime
  provider archive at zero. The immutable AWS provider remains exact at **989,311,138 bytes**.
  Pulumi successfully consumes both projected config values, advances from configured preview into
  `Updating (aws-eks-subzone)`, and creates its `awsProvider`; `route53:CreateHostedZone` then
  returns AWS 403 because the `prodbox-lifecycle-provider` identity has no policy allowing that
  action. Pulumi reports `+ 2 created`, `2 errored`, and update failure; the Provider returns
  `ProviderIntentExecutionMutationNotConfirmed`. Freeze the exact generated lifecycle-provider
  policy and the registered subzone program's required Route 53 action set, then locate their
  mismatch before changing policy, Provider, Pulumi, or harness behavior. The committed stack
  generation may exist, operational credentials remain preserved because exact cleanup was not
  proved, and the typed schema-memory live replacement, qualification, activation, preactivation,
  and writer cutover remain open. Source inspection locates the mismatch in
  `Prodbox.Lifecycle.CredentialProvisioner.ProductionIam.lifecycleProviderRolePolicy`: its DNS
  statement grants the registered record-management/read-back actions but omits the already-defined
  five-action hosted-zone lifecycle set `{ChangeTagsForResource, CreateHostedZone,
  DeleteHostedZone, ListHostedZones, ListTagsForResource}` required by the registered
  `aws-eks-subzone` zone resource. The parent NS record already fits the granted record-management
  set. Freeze the superseded and replacement policy/action projections under the same causal profile
  and exact `100m / 1,120Mi / 256Mi / 0 durable` envelope, then add only that five-action set to the
  fenced role; do not widen the role to `route53:*` or change Provider, Pulumi, harness, or capacity
  behavior.
- The hosted-zone authorization counterexample is code-local closed under that unchanged
  production profile. `Prodbox.Lifecycle.CredentialProvisioner.ProviderRoute53Policy` freezes the
  stable identity, one-fenced-worker/one-serialized-child/one-registered-stack/no-fault causal
  profile, exact `100m / 1,120Mi / 256Mi / 0 durable` old-to-new envelope, registered nine-action
  Route 53 set, superseded four-action record/read-back projection, denied-create disposition, and
  replacement projection. `lifecycleProviderRolePolicy` consumes the replacement value directly.
  Removing any registered action, changing the superseded set, adding `route53:*`, or changing the
  envelope fails the reproducer; the rendered role document contains every exact action and no
  wildcard. The two new reproducer cases pass **2/2** and the Route 53-focused selection passes
  **24/24**. The complete unit matrix passes primary **4,853/4,853** plus auxiliaries **27/27**,
  **35/35**, and **36/36**. Warning-clean all-target compilation, canonical `prodbox dev check` with
  HLint `No hints`, installed `clean-room-handoff`, installed `cli` **66/66** in **836.92 s**,
  installed `env` **66/66** in **831.92 s**, documentation, and diff gates pass. The exact installed
  executable is `sha256:4e786221750be31d434c351f23d27563360ac15880ee7ee4d6c825635722f503`.
  Rerun exact live `pre-1` with the Provider sampler. The policy-specific replacement closes live
  only when the registered hosted-zone create crosses this authorization boundary; the typed
  schema-memory replacement still separately requires successful exact Provider completion with
  zero OOM/restarts. Exact cleanup, qualification, activation, preactivation, and writer cutover
  remain unproved.
- The exact live rerun leaves the role-policy replacement open and exposes distinct stable
  counterexample `LIFECYCLE-PROVIDER-ASSUME-ROLE-SESSION-NOT-BOUND-2026-09-06`. Sampling starts at
  00:33:10 EDT; the run builds local image
  `sha256:2948ac52a60586f2679ce6ab7b1a20c2a5e4787f81e916d6a088317f569de3e9` in **1,155.6 s**,
  publishes Registry manifest
  `sha256:eb3cda8461eadf7d321d4386d1fb997e5aafc217d8da7d64ae992e0dd2d83929`, imports OCI
  manifest `sha256:1f7d74f704f7587d999aa96a12e8d94394aca047fe247e565458594cc7b3878f` in
  **132.9 s**, and removes only superseded Registry manifest `43df…` and local image `e132…`.
  Provider Worker generation 40 Pod `provider-worker-585ffc9bb4-4bh5n`, UID
  `d29ee41a-59f5-41d8-a4c8-657d454df1fb`, runs the exact new local image at
  `100m / 1,120Mi / 256Mi / 0 durable`, remains Ready, and has zero restarts. Its **517** samples
  contain **514** complete filesystem/cgroup observations: exact `memory.peak` is **1,069,260,800
  bytes** below `memory.max` **1,174,405,120 bytes**, every event count is zero, writable rootfs
  peaks at **51,142,656 bytes**, logs at **24,576 bytes**, working set at **961,261,568 bytes**,
  Pulumi home at **1,015,960 KiB**, `/tmp` at **12 KiB**, checkpoint scratch at **84 KiB**, runtime
  provider archive at zero, and the immutable provider remains **989,311,138 bytes**. The
  authenticated Credential Provisioner reports Lifecycle-provider generation 2 current after exact
  role-policy read-back, yet Pulumi's repeated `route53:CreateHostedZone` 403 names
  `arn:aws:iam::751103452346:user/prodbox-lifecycle-provider`, not an assumed-role session. It
  reports two unchanged resources, two errored resources, and update failure; Provider again returns
  `ProviderIntentExecutionMutationNotConfirmed`. Freeze the exact base-identity-to-assumed-role
  session projection under the same one-fenced-worker/one-serialized-child/one-registered-stack/
  no-fault causal profile and unchanged resource envelope, then locate where the deterministic role
  binding is lost before changing credential, session, Provider, Pulumi, harness, or capacity
  behavior. The registered stack lifecycle generation is committed and may exist, operational
  credentials remain preserved because exact cleanup was not proved, and the hosted-zone policy
  replacement, typed schema-memory replacement, qualification, activation, preactivation, and
  writer cutover remain open.
- Source inspection locates that lost binding at the production narrow-session boundary.
  `ProviderProduction.providerProductionNarrowSession` ignores both its closed `ProviderIntent` and
  absolute deadline, validates the exact Vault generation, then copies the assuming user's base
  `Settings.Credentials` directly into `ProviderProductionSession`. Every AWS CLI and Pulumi
  environment consumes that field, while `route53ClientForSession` reconstructs another base handle
  from it; the module contains no `AssumeRole` call. The provisioned user is intentionally incapable
  of provider effects and owns only `sts:AssumeRole` on the exact account-bound
  `prodbox-lifecycle-provider` role, and native `Prodbox.Aws.Native.Sts` already provides the only
  base-to-session constructor. Close the defect at the rank-2 boundary: derive the sole typed role
  from every constructor of the closed intent vocabulary, observe and validate the caller account,
  assume that exact role once, project the same temporary credentials to subprocesses and the opaque
  session handle to native clients, and discard both when the callback returns. The readiness probe
  must prove the same assumed-role path. Do not add a caller-controlled role string or alter the
  intent coordinate, deadline, Provider capability set, Pulumi program, harness, or resource
  envelope.
- The assumed-role session counterexample is code-local closed under that unchanged production
  profile. `Prodbox.ControlPlane.ProviderAssumedRoleSession` freezes its stable live identity,
  one-fenced-worker/one-serialized-child/one-registered-stack/no-fault causal profile, exact
  `100m / 1,120Mi / 256Mi / 0 durable` old-to-new envelope, base-user ARN, account-bound role ARN,
  fixed `prodbox-provider-worker` session name, AWS-minimum 900-second credential duration, and exact
  replacement assumed-role ARN. Every closed `ProviderIntent` constructor maps exhaustively to the
  sole typed role; first reconcile consumes the same role-name constant. Native STS now returns one
  constructor-hidden session containing both its opaque origin-indexed handle and the subprocess
  credential projection made directly from the same temporary response. Production observes and
  validates the base account/user, assumes the intent-selected role once, proves the exact assumed
  caller, supplies only that session to all capabilities, and makes Route 53 consume the session
  handle. Deep readiness traverses the same full path. The base credential never reaches a Provider
  effect; neither session projection can escape the rank-2 callback. The focused role/STS/production
  guards pass **8/8**. Warning-clean all-target compilation, the complete primary unit matrix
  **4,857/4,857**, installed auxiliaries **27/27**, **35/35**, and **36/36**, canonical `prodbox dev
  check` with HLint `No hints`, installed `clean-room-handoff`, installed `cli` **66/66** in
  **849.38 s**, installed `env` **66/66** in **846.24 s**, documentation, and diff gates pass. The
  exact installed executable is
  `sha256:c3d203fbeb3b17b7c20391ed9bae4739d445d95e2a775704b8a1fd171757c13a`. Rerun exact live
  `pre-1` with the Provider sampler. This session replacement, the Route 53 role-policy replacement,
  and the typed schema-memory replacement close live only after the registered stack crosses the
  verified assumed-role boundary and completes with zero OOM/restarts. Exact cleanup, qualification,
  activation, preactivation, and writer cutover remain unproved.
- The exact corrected live `pre-1` rerun crosses and live-closes
  `LIFECYCLE-PROVIDER-ASSUME-ROLE-SESSION-NOT-BOUND-2026-09-06`, then exposes distinct stable
  counterexample `LIFECYCLE-PROVIDER-ASSUMED-ROLE-ROUTE53-CREATE-DENIED-2026-09-06`. The run builds
  local image `sha256:5113218aea2205c83b50f6595f90a0830884209b94085854eff7fcd8a612eedd`
  in **1,163.2 s**, publishes Registry manifest
  `sha256:d36777713fb04a1500911dd32dc435a42eae0c9471aa60c1a92a40c384b1566e`, imports OCI manifest
  `sha256:de5d61e0d7f5a4fc756cce8a03578362dbd362d49f0cd5efddf6a5d8030447c0` in **129.5 s**, and
  removes only superseded Registry manifest `eb3c…` and local image `2948…`. Credential Provisioner
  generation 2 remains current. Provider Worker generation `7849c68fd7` Pod
  `provider-worker-7849c68fd7-rzjfl`, UID `357e5e85-ef78-4c85-8754-f737f23df6a6`, runs that exact
  image at the unchanged `100m / 1,120Mi / 256Mi / 0 durable` envelope, remains Ready, and has zero
  restarts. Across **534** samples (**530** complete filesystem/cgroup observations), writable
  rootfs peaks at **51,101,696 bytes**, logs at **24,576 bytes**, working set at **985,931,776
  bytes**, Pulumi home at **1,015,964 KiB**, `/tmp` at **12 KiB**, checkpoint scratch at **84 KiB**,
  runtime provider archive at zero, and exact `memory.peak` at **1,053,286,400 bytes** below
  `memory.max` **1,174,405,120 bytes**; every cgroup memory event remains zero. AWS identifies the
  Provider caller as the exact replacement
  `arn:aws:sts::751103452346:assumed-role/prodbox-lifecycle-provider/prodbox-provider-worker`,
  proving the rank-2 assumed-role session reached the effect. The same registered
  `aws-eks-subzone` action still returns 403 `AccessDenied` for `route53:CreateHostedZone` because
  no identity-based policy on that assumed role allows the action; Pulumi reports two unchanged
  resources, two errored resources, and update failure, and Provider returns
  `ProviderIntentExecutionMutationNotConfirmed`. Freeze this assumed-caller denial under the same
  one-fenced-worker/one-serialized-child/one-registered-stack/no-fault causal profile and unchanged
  resource envelope, then locate why the already-authored exact nine-action policy is not effective
  on the live role before changing IAM reconciliation, policy, Provider, Pulumi, harness, or
  capacity behavior. The earlier hosted-zone policy replacement and typed schema-memory replacement
  remain live-open because hosted-zone creation did not cross and the Provider did not complete.
  The registered stack generation is committed and may exist; operational credentials remain
  preserved because exact cleanup was not proved, and qualification, activation, preactivation,
  and writer cutover remain unproved.
- Source inspection locates the live-policy mismatch in the durable operation coordinate rather
  than the IAM interpreter. `ensureProgramRole` unconditionally updates and reads back the exact
  trust, puts the exact inline role policy, and requires policy-equivalent read-back before key
  creation. The qualification cycle instead finds the already-completed Generation-2 operation
  under the scope/class/generation-only `normalAwsAdminOperationIdForScope`;
  `coordinateAwsAdminProvisioning` returns its retained receipt without creating a worker, so the
  newly authored policy program never executes. The live line “credential is current” therefore
  proves only retained receipt recovery, not current IAM-program reconciliation. Close the
  counterexample without rewriting completed state: derive a secret-free semantic revision from
  the canonical Lifecycle-provider role-policy document, bind it into both lookup and compilation
  scopes, and let policy change select a fresh durable operation plus the ordinary next Target
  generation. That operation must traverse the existing exact put/read-back prerequisite before
  key creation. Freeze the superseded unversioned completed-replay scope and replacement
  revision-bound scope under the unchanged causal/resource profile, and prove policy-document
  mutation changes the operation coordinate. Do not rerun prerequisites inside an old completed
  replay, mutate its retained intent/receipt, weaken exact policy read-back, or change the Provider,
  Pulumi, capacity, deadline, or harness cleanup behavior.
- The assumed-role Route 53 denial is code-local closed without changing that causal or resource
  profile. `Prodbox.Lifecycle.CredentialProvisioner.ProductionIam` now exports the canonical
  Lifecycle-provider role-policy document consumed by the existing exact put/read-back program,
  and `Prodbox.Lifecycle.CredentialProvisioner.ProviderRolePolicyOperationScope` derives semantic
  revision `bacc2854e31887da758e66bf3d8574e8399086511289ea57d59f75bd8e55394a` as SHA-256 over the
  domain-separated canonical document. The harness binds
  `role-policy-sha256-bacc2854e31887da758e66bf3d8574e8399086511289ea57d59f75bd8e55394a` into
  both durable lookup and intent-compilation scope. The immutable unversioned Generation-2
  completion therefore cannot mask the changed policy: replay remains exact within one revision,
  while this revision selects a successor operation and the ordinary next Target generation whose
  existing IAM program must put and independently read back the exact policy before access-key
  creation. The frozen counterexample validator fixes the stable identity, unchanged
  one-fenced-worker/one-serialized-child/one-registered-stack/no-fault profile, unchanged
  `100m / 1,120Mi / 256Mi / 0 durable` envelope, superseded and replacement scopes, exact revision,
  and a mutation that removes `route53:CreateHostedZone`; that mutation changes the operation ID.
  Focused new/existing revision, drift, Route 53 policy, and role read-back regressions pass
  **4/4**. The complete primary suite passes **4,859/4,859** in **89.15 s**, installed auxiliaries
  pass **27/27**, **35/35**, and **36/36**, canonical `prodbox dev check` passes with pinned
  formatting, HLint `No hints`, and warning-clean all-target compilation, installed
  `clean-room-handoff` passes, installed `cli` passes **66/66** in **842.27 s**, installed `env`
  passes **66/66** in **837.50 s**, and the documentation and diff gates pass. The exact installed
  executable is
  `sha256:6b93c9a84f878dd345ea4b42f1e23948f89e0fff6cb88eb2927dc09117f348d3`. Rerun exact live
  `pre-1` with the Provider sampler. This policy-operation replacement, the earlier exact Route 53
  policy replacement, and the typed schema-memory replacement close live only after the successor
  credential generation is observed, the registered stack crosses hosted-zone creation, and the
  Provider completes with zero OOM/restarts. Exact cleanup, qualification, activation,
  preactivation, and writer cutover remain unproved.
- The exact revision-bound live `pre-1` rerun crosses the immutable-completion replay boundary but
  exposes stable counterexample
  `AWS-ADMIN-REVISIONED-TARGET-WORKER-INSUFFICIENT-CPU-2026-09-06` before Provider execution. It
  builds local image
  `sha256:067589ea66c01f86861f89fcc9204bc1eb70b1b95d60b446328dca4289997698` in **1,142.0 s**,
  publishes Registry manifest
  `sha256:eb8d5a2ca1fd0e3249342acf99e0efef9c38e099d061ac846d67abb1f57af911`, imports OCI manifest
  `sha256:d5f8fe4455126786d9b685b83aec66d716c813bde871ff35638d9e4af6b1d428` in **130.0 s**, and
  removes only superseded Registry manifest `d367…` and local image `5113218…`. Semantic policy
  revision `bacc2854…` selects fresh operation
  `normal-a4769763c0e4571ff78713abb1c27c0e0fa08777f777845b`, proving the replacement scope no
  longer replays the unversioned Generation-2 completion. That parent Job and each Target
  materializer use the unchanged Guaranteed `250m / 256Mi / 256Mi / 0 durable` one-shot envelope.
  The Ready, pressure-free, untainted 8-core node exposes **7,500m** allocatable CPU but already
  carries **7,245m** of requests; with the parent scheduled, only **5m** remains. Kubernetes
  therefore creates Target Job
  `target-secret-e4aa1a01ab2a6eb71ed5566417fe40663de06ac5` twice and refuses both Pods with
  `Insufficient cpu`. The exact protected terminal is
  `execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/observation-failed/container-status-missing`;
  the public coordinator result remains `AwsAdminWorkerReceiptDecodeFailed` and the supported
  command exits 1. Postflight proves both one-shot namespaces contain no Job or worker Pod; the
  standing Target Agent is Ready with zero restarts. The single permitted Target Agent log is empty
  and the single permitted Authority log reports `aws-admin/prepare authority-phase=vacant`. The
  Provider is never rolled or invoked: across **787** samples (**784** complete), old Pod
  `provider-worker-7849c68fd7-rzjfl`/UID `357e5e85-ef78-4c85-8754-f737f23df6a6` remains Ready
  with zero restarts on old manifest `d367…`; its sampled cgroup event vector stays all-zero, while
  rootfs peaks at **51,101,696 bytes**, logs at **24,576 bytes**, working set at **32,337,920
  bytes**, and Pulumi home at **1,015,964 KiB**. Freeze this no-fault retained-home topology, exact
  two overlapping one-shot envelopes, 8-core host, **7,500m** kubelet allocatable, **7,245m**
  standing request draw, and the complete topology-normalized capacity total before changing
  resource allocation, scheduling, delivery observation, retry, receipt, IAM, or Provider
  behavior. The earlier assumed-role Route 53 denial and schema-memory counterexamples remain
  live-open because hosted-zone creation and Provider completion are not reached. Operational
  credentials remain preserved because exact terminal cleanup is not proved; qualification,
  activation, preactivation, and writer cutover remain unproved.
- The scheduler counterexample is now code-local closed by the repository-owned no-fault
  reproducer in `Prodbox.Capacity.OneShotWorkerSchedulerBudget`. It freezes the exact retained-home
  topology, **7,245m** standing request draw, parent-plus-Target overlap, and the common Guaranteed
  `250m / 256Mi / 256Mi / 0 durable` envelope. The superseded plan fails at **7,745m required**
  against **7,500m allocatable** (**245m deficit**); the replacement transfers exactly **250m** CPU
  from `rke2_reserved` to `eviction_floor`, so it admits the same schedule at **7,745m required**
  against **7,750m allocatable** (**5m headroom**). Host capacity, every workload profile, all
  non-CPU axes, and the topology-normalized total remain unchanged: workload draw is
  `6210m / 9984Mi / 15456Mi / 155648Mi`, while reservation + eviction + draw remains
  `7210m / 12544Mi / 35424Mi / 157696Mi`. `renderRke2SystemdResourceGuardrail` now derives its
  CPU budget from reservation plus eviction, preserving the exact **1,000m** systemd containment
  while kubelet receives the new `125m + 125m` CPU reservation halves and unchanged memory/storage
  halves. The committed Dhall schema and both RKE2 plan goldens are regenerated. Focused scheduler,
  drift, kubelet-render, and systemd-render regressions pass **4/4**; the complete primary suite
  passes **4,861/4,861** in **87.64 s**, and the installed run passes **4,861/4,861** in **88.61 s**
  plus auxiliaries **27/27**, **35/35**, and **36/36**. Warning-clean all-target compilation and
  canonical `prodbox dev check` pass; installed `clean-room-handoff` passes, installed `cli` passes
  **66/66** in **846.21 s**, and installed `env` passes **66/66** in **846.17 s**. The synchronized
  executable is exact at
  `sha256:8a710eb2f5108c316cd5a60627562da8ebea752acf566f43a8732fc6f7409e93`. Post-ledger
  documentation, repository-file, and diff gates pass. Rerun exact live
  `pre-1` with the Provider sampler. This scheduler replacement, the earlier exact Route 53 policy
  and revision-bound operation replacements, and the typed schema-memory replacement close live
  only after the successor credential generation is observed, hosted-zone creation is crossed,
  and the Provider completes with zero OOM/restarts. Exact cleanup, qualification, activation,
  preactivation, and writer cutover remain unproved.
- The exact scheduler-corrected live `pre-1` replay reaches stable counterexample
  `AWS-ADMIN-AUTHORIZED-CLEANUP-PROVEN-STATE-TRANSITION-REJECTED-2026-09-06` before creating a
  Credential Provisioner Job. It writes the new kubelet guardrail and read-back exposes exactly
  **7,750m** allocatable CPU on the Ready, pressure-free, untainted 8-core node, proving the
  replacement allocation reached production but not yet exercising the two-worker schedule. The
  run builds local image
  `sha256:f1cab908cf206fef1b1cd40986eb4c73f829265a7a1b8471dc3a018e436f46af` in **1,156.0 s**,
  publishes Registry manifest
  `sha256:de569449fbb73943e23801fcf322b507ec66820be17d2e10f611061f67e40ed1`, imports OCI manifest
  `sha256:346ab5b210e6b3a50ca19e33d4a919e27ffedd15fae9ed3a2ba5278b877c3d9a` in **124.9 s**, and
  removes only superseded Registry manifest `eb8d…` and local image `067589…`. The retained
  revision-bound operation is `authorized`; its exact execution journal is
  `present/cleanup-proven/remint-used`. Job/Pod absence and that cleanup proof admit the typed
  authorized-recovery path, but the Authority returns `state-transition-rejected`; the public
  terminal is `AwsAdminCoordinatorPrepareFailed (AwsAdminProvisionerClientRefused
  "state-transition-rejected")`. No Credential Provisioner or Target worker remains or was created,
  the standing Target Agent is Ready with zero restarts, and its single permitted log is empty. The
  single permitted Authority log records exactly `aws-admin/prepare authority-phase=authorized`
  and `aws-admin/recovery journal-observation=present/cleanup-proven/remint-used`.
- Source inspection locates the rejection in `renewalCoreBindingsMatch`: all immutable normal-
  operation bindings agree, including `awsAdminPermitIntentPlanBinding retained ==
  awsAdminPermitIntentPlanBinding replacement == Nothing`, but the predicate additionally requires
  the retained plan binding to be non-empty. That requirement describes first-reconcile members
  and incorrectly rejects an exact post-first-reconcile normal credential recovery. Freeze the
  same operation, expired Authorized permit, exact absent Job/Pod observations,
  cleanup-proven/remint-used journal, normal credential/action/generation/request/IAM/scope/endpoint
  bindings, `Nothing`/`Nothing` plan binding, and outbox-before-state ordering. Close only the false
  non-empty restriction while retaining exact equality; a missing binding must remain invalid for
  first-reconcile/Genesis state, and any `Just`/`Nothing`, unequal `Just`, request, operation,
  generation, prepared-target, cleanup-predecessor, or deadline drift must still refuse. Across
  **671/671** complete Provider samples, only old Pod
  `provider-worker-7849c68fd7-rzjfl`/UID `357e5e85-ef78-4c85-8754-f737f23df6a6` appears on old
  manifest `d367…`; it is never Ready, has zero restarts and zero cgroup events, and the new
  Provider image is never rolled or invoked. Its sampled rootfs peaks at **51,101,696 bytes**, logs
  at **24,576 bytes**, working set at **35,127,296 bytes**, Pulumi home at **1,015,964 KiB**, and
  cgroup memory peak at **1,053,286,400 bytes** under the unchanged **1,174,405,120-byte** maximum.
  The scheduler, Route 53 denial, and schema-memory counterexamples remain live-open because the
  parent/Target overlap, hosted-zone creation, and Provider completion are not reached. Operational
  credentials remain preserved because exact terminal cleanup is not proved; qualification,
  activation, preactivation, and writer cutover remain unproved.
- The code-local correction for
  `AWS-ADMIN-AUTHORIZED-CLEANUP-PROVEN-STATE-TRANSITION-REJECTED-2026-09-06` is complete and the
  counterexample remains **live-open** pending an exact `pre-1` replay.
  `renewalCoreBindingsMatch` now requires exact plan-binding equality without separately requiring
  a non-empty retained binding: first-reconcile/Genesis renewal remains `Just`/`Just`, normal
  post-first-reconcile renewal admits only `Nothing`/`Nothing`, and asymmetric or unequal bindings
  still refuse. The frozen regression proves the cleanup-proven/remint-used post-first-reconcile
  path commits only after `outbox-readback` then `state-cas`, while the paired first-reconcile
  missing-binding case continues to return `AwsAdminAuthorityRenewalBindingMismatch`. The exact
  regression passes **1/1** in **0.04 s**, the complete AWS-admin Credential Provisioner Authority
  group passes **53/53** in **0.08 s**, the source-tree primary suite passes **4,862/4,862** in
  **89.04 s**, and the installed primary suite passes **4,862/4,862** in **88.75 s** with
  auxiliary suites **27/27**, **35/35**, and **36/36**. Warning-clean all-target compilation,
  canonical `prodbox dev check`, installed `clean-room-handoff`, CLI **66/66** in **843.73 s**,
  environment **66/66** in **846.16 s**, documentation consistency/lint, repository-file lint,
  and `git diff --check` all pass. The synchronized executable is
  `sha256:0a472f6f635b0f5b13dc8a4855102da2f727a4d69c2f73c14c85f3d213bfc3c0`. Rerun exact live
  `pre-1` with the Provider sampler; the scheduler, Route 53 denial, and schema-memory replacements
  remain live-open until that replay reaches their respective proof boundaries, and no
  qualification, activation, preactivation, writer-cutover, or exact-cleanup claim is yet
  licensed.
- The exact corrected live `pre-1` replay closes
  `AWS-ADMIN-AUTHORIZED-CLEANUP-PROVEN-STATE-TRANSITION-REJECTED-2026-09-06`, the one-shot
  scheduler capacity counterexample, the exact Route 53 create permission denial, and the Provider
  schema-memory/OOM counterexample, then reaches stable counterexample
  `AUTHORITY-PROVIDER-DISPATCH-RESPONSE-INVALID-2026-09-06`. It builds local image
  `sha256:eb4354dd63ea637d5b863a5988442ea4afb6b71188daa8cacef23805e4777fde` in **1,154.4 s**,
  publishes Registry manifest
  `sha256:766cf54d9c6475a5d6f4897073bd6f520ed54c6803743a96e49a81b00e178c1e`, imports OCI manifest
  `sha256:104d60b7c4732a0735b4d790ceff119adc0e690e2a130e0a313271258399c30f` in **128.3 s**, and
  removes only superseded Registry manifest `de569449…` and local image `f1cab908…`. Exact events
  show the Credential Provisioner started at `12:27:42Z` and its Target worker started eleven
  seconds later at `12:27:53Z`; both schedule on the corrected 7,750m allocatable node, all
  one-shot resources are absent afterward, and the authenticated lifecycle-provider credential
  reaches generation **3**. The AWS EKS subzone create returns a settled Provider receipt,
  crossing the previous CreateHostedZone denial. The replacement Provider Pod
  `provider-worker-6dcff4f4b6-29jdm`/UID `4badf3fb-afe7-47b7-8c6c-22627ae139dc` runs the exact new
  manifest for **706** complete samples, **701** Ready, with zero restarts and every observed
  cgroup counter zero. Its sampled rootfs peaks at **51,113,984 bytes**, logs at **36,864 bytes**,
  working set at **753,901,568 bytes**, Pulumi home at **1,015,968 KiB**, `/tmp` at **12 KiB**,
  `/dev/shm` at **296 KiB**, plugin archive residue at **0 bytes**, and cgroup memory peak at
  **1,117,913,088 bytes** under the unchanged **1,174,405,120-byte** maximum.
- The later registered stack lifecycle generation is durably committed as
  `AwsStackCreationCommitCreated`, but execution of its admitted create fails at the host client
  with `AuthorityProviderResponseInvalid ControlPlaneRequestInvalid`; a stack may therefore exist
  under that cycle. The Authority endpoint is specified to return canonical
  `ProviderDispatchResponse` CBOR and the client decodes that exact type, so freeze the exact
  authenticated route, HTTP status class, response-size/emptiness/codec shape, known bounded
  plaintext classification, admitted operation, committed generation, and outbox/state ordering
  in a value-free diagnostic before changing endpoint encoding, authentication, dispatch,
  settlement, or Provider execution. The single permitted Target Agent log records
  `target-one-shot/tls-verify failure=coordinator/attach-failed/provisional-read-unavailable`; the
  single permitted Authority log records the successful authorized
  `present/cleanup-proven/remint-used` recovery plus non-terminal TLS-retention selected-Agent HTTP
  failure. No other Kubernetes logs were read. Exact cleanup is unproved, operational credentials
  remain preserved, and qualification, activation, preactivation, and writer cutover remain
  unproved.
- The behavior-neutral diagnostic for
  `AUTHORITY-PROVIDER-DISPATCH-RESPONSE-INVALID-2026-09-06` is code-locally complete and the
  counterexample remains **live-open**. `AuthorityProviderResponseInvalid` now retains only a
  closed observation of HTTP status class, empty/within-bound/over-bound size, and direct
  canonical, endpoint-success wrapper, endpoint-failure wrapper, exact known authenticated-role
  plaintext, empty, or other response shape. It neither retains response bytes nor accepts any
  newly recognized shape. Distinct private direct, wrapper-success, wrapper-failure, and arbitrary
  values collapse to the same respective observations; the client continues to fail closed on
  every decode error. The exact diagnostic regression passes **1/1** in **0.05 s**, its
  Provider-dispatch selection passes **17/17** in **0.07 s**, the source-tree primary suite passes
  **4,863/4,863** in **88.84 s**, and the installed primary suite passes **4,863/4,863** in
  **88.14 s** with auxiliary suites **27/27**, **35/35**, and **36/36**. Warning-clean all-target
  compilation, canonical `prodbox dev check`, installed `clean-room-handoff`, CLI **66/66** in
  **848.63 s**, environment **66/66** in **838.24 s**, documentation consistency/lint,
  repository-file lint, and `git diff --check` all pass. The synchronized executable is
  `sha256:d61c1b837ec2e2635f8bd2daf9d86a16ed43570ab69ac675f0ab7693e95298a9`. Rerun exact live
  `pre-1` with the Provider sampler to expose the value-free response shape before changing the
  Provider endpoint; exact cleanup, qualification, activation, preactivation, and writer cutover
  remain unproved.
- The exact diagnostic live `pre-1` replay is blocked before the AWS Provider-response boundary by
  stable counterexample
  `HOME-PATRONI-RETAINED-THREE-ORDINAL-RESTORE-NONCONVERGENCE-2026-09-06`. It builds local image
  `sha256:45b8e3081542051c8aa29c831b17c1f85d62db929a86bb7802f4a39c559df1a9` in **1,146.7 s**,
  publishes Registry manifest
  `sha256:c4865aa54f2dd3742a22f5e2c2936d30bea859beebbc743363953f69f1f86460`, imports OCI manifest
  `sha256:ef5438758b83e2169d10d5764a077e33ecf7ffa7f5face082a39284493ffa5ae` in **113.9 s**, and
  removes only superseded Registry manifest `766cf54d…` and local image `eb4354dd…`. The
  authenticated lifecycle-provider credential remains current at generation **3**. During the
  clean-room restore, the retained ordinal-0 Patroni member
  `prodbox-vscode-pg-instance1-rpj4-0` becomes database- and replication-ready with zero restarts,
  but retained follower members `prodbox-vscode-pg-instance1-v945-0` and
  `prodbox-vscode-pg-instance1-w668-0` remain database-unready/replication-ready with zero restarts
  for the complete **1,800-second** convergence budget. The Percona CR has generation **2** observed
  at **2**, state `initializing`, Patroni **4.1.0**, a present system identifier,
  `ProxyAvailable=True`, and `ReadyForBackup=False`; all three Pods remain Running and all three
  PVCs remain Bound to the exact retained PV inventory. The restore graph therefore records Delete
  websocket/API/gateway, Ensure Gateway MinIO, Reconcile gateway/API/websocket, and Wait public edge
  as successful, while Delete Vscode and Reconcile Vscode return `ExitFailure 1`; its terminal
  observation is `status=initializing,postgres.ready=1,expected.postgres.ready=3`. Public edge
  remains ready and Vault remains initialized and unsealed. Across **1,802** Provider samples, the
  superseded Provider Pod has **726/726** complete Ready observations and the diagnostic Provider
  Pod `provider-worker-57dd68b54f-25wnk`/UID `aa2bd236-fd0e-4a27-8859-9f4fe30f96d5` has
  **1,075** samples, **1,070** Ready, zero restarts, a **72,429,568-byte** working-set peak,
  **966,172 KiB** Pulumi-home peak, and **90,976,256-byte** cgroup memory peak under the unchanged
  **1,174,405,120-byte** maximum; it is not invoked for AWS. All **1,789** complete cgroup event
  observations are zero. The single permitted Target Agent log is empty; the single permitted
  Authority log records completed AWS-admin preparation and the existing non-terminal
  TLS-retention selected-Agent HTTP failure. No other Kubernetes logs were read. Freeze the
  retained-anchor selection, exact pre-reconcile follower-root reset effects, new random-suffix
  follower claims, ordinal/PV assignment, one-member readiness, three-member expansion, and
  terminal CR/member observations before changing storage reset or staged-restore ordering. The
  Provider-response diagnostic remains **live-open** because this replay never reaches AWS; exact
  cleanup is unproved, operational credentials remain preserved, and qualification, activation,
  preactivation, and writer cutover remain unproved.
- The code-local correction for
  `HOME-PATRONI-RETAINED-THREE-ORDINAL-RESTORE-NONCONVERGENCE-2026-09-06` is complete and the
  counterexample remains **live-open**. The retained-root reset now treats an exact live-primary
  observation as an in-place reconcile and preserves all three active roots; only the
  no-live-primary retained-restore branch preserves ordinal `0` while resetting existing follower
  roots `1` and `2`. This closes the measured causal sequence: the affected Pods were created at
  `12:46Z`, the second reconcile recreated the follower host directories at `14:32Z`, both host
  paths remained empty, and the unchanged Helm apply left the running follower Patroni processes
  mounted across that removal. The stable installed-boundary regression preserves sentinels in all
  three roots under an exact live primary and passes in **3.50 s**; temporarily restoring the
  superseded live-primary reset deletes a follower sentinel and fails that same regression in
  **19.90 s**, after which the corrected source is restored byte-exactly at
  `sha256:ccee598c035b7065e36b49e7b191f78d237f93522e81c09612926dbf3e1ec57d` before canonical
  formatting. Its paired no-live-primary case proves the ordinal-0 sentinel survives while both
  follower sentinels are removed and passes in **3.49 s**. Canonical `prodbox dev check`, HLint
  (`No hints`), and warning-clean all-target compilation pass. The primary suite passes
  **4,863/4,863** in **88.46 s**; the installed unit entrypoint passes in **123.62 s** with
  auxiliary suites **27/27**, **35/35**, and **36/36**; installed `clean-room-handoff` passes; CLI
  passes **67/67** in **849.62 s**; environment passes **67/67** in **838.58 s**; documentation
  consistency/lint, repository-file lint, and `git diff --check` all pass. The synchronized
  executable is
  `sha256:8a809f6d4a7f3455b9e6a4e0e7e1ff8173b19b9c04f5cb26f271f7f6311d4b3a`. Repair the
  already-affected retained deployment through a supported `prodbox` chart lifecycle, then rerun
  exact live `pre-1` with the Provider sampler. The Provider-response diagnostic remains live-open;
  exact cleanup, qualification, activation, preactivation, and writer cutover remain unproved.
- The supported clean-room repair first proves local `cluster delete --yes`: RKE2, its managed
  kubeconfig, and the local firewall residue are removed while exact retained root
  `.test-data/legacy-aggregate` and its Vault PV remain preserved, and no AWS absence is claimed. A
  targeted `charts delete vscode --yes` attempt had correctly refused before chart mutation at the
  already-registered `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`; its one permitted
  Target Agent log was empty and its one permitted Authority log selected the existing
  `selected-agent/http-status/other` arm. The following exact corrected `pre-1` replay reaches new
  stable counterexample
  `MINIO-REGISTRY-ADMISSION-FRESHNESS-EXHAUSTED-CLEAN-INSTALL-2026-09-06` before Patroni restore,
  image build, Provider deployment, or AWS. On synchronized executable
  `sha256:8a809f6d4a7f3455b9e6a4e0e7e1ff8173b19b9c04f5cb26f271f7f6311d4b3a`, it installs RKE2
  `v1.36.4+rke2r1`, observes the exact 8,000m/15,930 MiB/238,221 MiB host against the admitted
  8,000m/15,930 MiB/44,280 MiB ephemeral/182,030 MiB durable plan, reaches a Ready node, installs
  fresh MinIO release revision **1** at `12:25:33`, and installs fresh Vault release revision **1**
  at `12:25:52`. Registry admission then refuses because the MinIO observation is **31,305,921
  us** old, past the edge's **30,000,000 us** bound. The **90-sample** Provider trace from
  `16:23:23.403Z` through `16:26:28.943Z` is uniformly absent, as expected before that deployment.
  No Kubernetes logs were read for this replay. Freeze the MinIO observation timestamp, its exact
  MinIO-to-Registry edge freshness derivation, the sequential Vault work charged between
  observation and consumption, and the clean-install topology/load before changing freshness,
  observation placement, graph ordering, or retry behavior. The retained-Patroni and
  Provider-response counterexamples remain **live-open** because neither boundary is reached;
  exact cleanup, qualification, activation, preactivation, and writer cutover remain unproved.
- The code-local correction for
  `MINIO-REGISTRY-ADMISSION-FRESHNESS-EXHAUSTED-CLEAN-INSTALL-2026-09-06` is complete and the
  counterexample remains **live-open**. Registry has exactly two graph-declared dependencies in
  order, `cluster_base` and MinIO; the former was already refreshed by the executor's
  single-expiry retry, and complete-set revalidation then exposed the latter as the terminal
  30,000,001-us-old admission. `runAnchoredStepOrder` now re-observes each distinct expired
  dependency revealed by complete-set revalidation at most once. It does not widen the
  graph-derived **30,000,000 us** bound: a failed re-observation, a dependency that expires again
  while its siblings are refreshed, or a never-observed dependency still refuses. The stable
  regression fixes the exact Registry dependency order and supplies both admissions one
  microsecond past the bound. Against the superseded executor it fails in **0.05 s** with
  `AdmissionExpired ComponentRegistry ComponentMinio 30000001 30000000`; against the correction
  it passes **1/1** in **0.03 s** and proves both dependencies are re-observed before mutation.
  Bootstrap Readiness Doctrine now states that complete-set rule. Canonical `prodbox dev check`,
  HLint (`No hints`), and warning-clean all-target compilation pass. The installed unit entrypoint
  passes its primary **4,864/4,864** inventory in **87.34 s** plus auxiliary suites **27/27**,
  **35/35**, and **36/36**; installed `clean-room-handoff` passes; CLI passes **67/67** in
  **846.06 s**; environment passes **67/67** in **836.34 s**; and documentation consistency/lint,
  repository-file lint, and `git diff --check` all pass. The synchronized executable is
  `sha256:70f26f59ae3052ed44e3faa372ae86e99566a7634446a84f74670597e0e2959e`. Rerun exact live
  `pre-1` with the Provider sampler. Retained-Patroni convergence, the Provider-response
  diagnostic, exact cleanup, qualification, activation, preactivation, and writer cutover remain
  unproved.
- The corrected retained-cluster `pre-1` replay live-closes
  `HOME-PATRONI-RETAINED-THREE-ORDINAL-RESTORE-NONCONVERGENCE-2026-09-06` but deliberately does
  **not** close the exact clean-install MinIO freshness counterexample. The run starts at
  `13:30:49` EDT with the RKE2/MinIO/Vault installation retained from the preceding failed clean
  install, crosses Registry admission and rollout in three reconcile cycles, builds local image
  `sha256:0d2766d27d977395a372f3fc32b6c16960aab9d2eeb09955ad64bf79de84f23c` in **992.3 s**,
  publishes Registry manifest
  `sha256:d8c31a0e89359583b98211d7f357bd90a6547bd9983095830b2e031920c56f4d`, and imports OCI
  manifest `sha256:11bec7eb21f5aa5d393085511ce118abb7f833d9dd49f25c2920e99ac9aff253`
  in **211.5 s**. It removes only superseded Registry manifest `c4865aa5…` and local image
  `45b8e308…`. The retained Percona resource reaches generation **2** observed at **2**,
  `state=ready`, Patroni **4.1.0** with the same system identifier, and PostgreSQL **3/3**. All
  three newly suffixed members are database- and replication-ready with zero restarts and their
  claims bind the exact retained PVs `0`, `1`, and `2`; VS Code, Keycloak, API, WebSocket, and
  public edge then reconcile, and the edge classifies `ready-for-external-proof`. This is exact
  live closure of the follower-root correction.
- The run terminates at `14:19:36` EDT because the already-registered
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable` makes only RestoreNode Delete Vscode
  fail; the total restore graph subsequently reconciles Vscode successfully and every other node
  succeeds. The single permitted Target Agent log is empty; the single permitted Authority log
  records completed AWS-admin preparation and two `selected-agent/http-status/other` TLS failures.
  No other Kubernetes logs were read. Provider Worker remains one Ready zero-restart Pod on the
  exact image and unchanged 1,120-MiB envelope. Of **1,355** sampler rows, **419** name that Pod
  and **414** are Ready; all **417** complete cgroup-event observations are zero. Sampled peaks are
  **69,632 bytes** rootfs, **16,384 bytes** logs, **34,881,536 bytes** working set, **966,172 KiB**
  Pulumi home, **12 KiB** `/tmp`, zero `/dev/shm` and plugin archive residue, and **82,227,200
  bytes** cgroup memory under the unchanged **1,174,405,120-byte** maximum. No AWS Provider request
  is reached and the authenticated lifecycle-provider credential remains generation **3**.
  Because MinIO and Vault were upgrades rather than the frozen fresh installations whose
  sequential latency produced the 31,305,921-us admission,
  `MINIO-REGISTRY-ADMISSION-FRESHNESS-EXHAUSTED-CLEAN-INSTALL-2026-09-06` remains **live-open**.
  Supported local `cluster delete --yes` then succeeds: local RKE2 and its managed kubeconfig are
  removed, the Gateway firewall rule is not present, exact retained root
  `.test-data/legacy-aggregate` and its Vault PV remain preserved, and no AWS absence is claimed.
  Run exact fresh live `pre-1` with the Provider sampler. The Provider-response diagnostic, exact
  cleanup, qualification, activation, preactivation, and writer cutover remain unproved.
- The exact fresh-install replay live-closes
  `MINIO-REGISTRY-ADMISSION-FRESHNESS-EXHAUSTED-CLEAN-INSTALL-2026-09-06` and reaches new stable
  counterexample
  `REGISTRY-NODEPORT-READBACK-CONNECTION-REFUSED-AFTER-READY-CLEAN-INSTALL-2026-09-06`. From
  `14:22:45` through `14:27:04` EDT it installs RKE2 `v1.36.4+rke2r1`, admits the exact observed
  8,000m/15,930 MiB/238,221 MiB host against the 8,000m/15,930 MiB/44,280 MiB
  ephemeral/182,030 MiB durable plan, installs fresh MinIO revision **1** at `14:24:31`, and
  installs fresh Vault revision **1** at `14:24:49`. The same clean-install sequential work that
  previously made MinIO **31,305,921 us** old now crosses Registry admission with the unchanged
  **30,000,000-us** graph bound; bucket initialization completes and all three Registry rollout
  generations report success. That is exact live closure of the bounded multi-dependency refresh.
- The immediately following Registry-manifest retention read-back fails with `curl: (7) Failed to
  connect to 127.0.0.1 port 30080 after 0 ms`; no image build, Provider deployment, or AWS request
  is reached, and all **130** Provider samples are uniformly absent. At terminal time the final
  Registry Deployment is generation **3** observed at **3**, `1/1` Ready/Available/Updated. Its
  zero-restart Pod/UID
  `registry-6c595f8955-5mqmd`/`20d09af4-3230-48cd-a26e-92763aae8d3a` was created at `18:26:35Z`,
  started and became Ready at `18:26:36Z`, with Pod IP `10.42.0.15`. The `harbor` Service and
  EndpointSlice were created at `18:25:31Z`; the exact endpoint is Ready and serving on target port
  `5000`, and the Service projects NodePort `30080`. Kube-proxy and the node are Ready,
  zero-restart, and pressure-free. At `14:28:01` EDT, only **57 seconds** after terminal failure,
  read-only GETs through both `127.0.0.1:30080/v2/` and `192.168.2.46:30080/v2/` return `{}`. No
  Kubernetes logs were read for this run. Freeze the exact fresh Service/EndpointSlice creation,
  three rollouts, final ready Pod, kube-proxy/node state, immediate host read-back refusal, and
  later positive loopback/node-IP reads before changing Registry readiness, read-back retry,
  kube-proxy settling, or retention behavior.
- The correction for
  `REGISTRY-NODEPORT-READBACK-CONNECTION-REFUSED-AFTER-READY-CLEAN-INSTALL-2026-09-06` is
  **code-local, mutation-proven, and live-closed**. `captureRegistryApi` now repeats
  only a started `curl` whose non-zero result the shared transient-transport classifier
  recognizes. Its named `registryReferenceObservationRetryPolicy` permits sixteen attempts
  separated by jittered five-second delays, retaining at least the measured sixty-second residual
  NodePort-settling window. Process-start failure, unclassified HTTP failure, every
  successful-but-malformed Registry response, page-bound exhaustion, and snapshot disagreement
  remain immediately terminal; the retry never repeats garbage collection. The installed-boundary
  regression bearing the exact counterexample name injects one connection refusal on only the
  second catalog request. With the old executor it fails in **96.04 s** at the exact read-back
  error; with the correction it passes **1/1 in 104.44 s**, records exactly three catalog
  requests, and completes the same reconcile and delete path. Focused policy and shared-classifier
  checks pass **6/6**. The synchronized executable is
  `sha256:72a404417c8ef1b8b679eab85559883b969b206c6d3b6d420e99a120da4b0f79`. Full local
  validation is green: canonical `prodbox dev check` exits zero with no HLint hints and a
  warning-clean build; installed unit passes **4,864/4,864** plus **27/27**, **35/35**, and
  **36/36** auxiliary cases; installed `clean-room-handoff` passes; CLI integration passes
  **67/67 in 839.42 s** and environment integration passes **67/67 in 830.88 s**; documentation
  check/lint, file lint, and `git diff --check` all exit zero. The supported pre-replay
  `cluster delete --yes` then exits zero, positively removes RKE2 and the managed kubeconfig,
  observes the Gateway firewall rule absent, preserves the retained manual-PV/Vault root, and
  makes no AWS-absence claim.
- The exact fresh-cluster replay from **15:37:04 through 16:28:55 EDT** installs RKE2
  `v1.36.4+rke2r1`, reaches the same immediate `curl (7) Failed to connect … Couldn't connect`
  failure after the first Registry rollout, emits exactly `Retrying Registry reference
  observation after transient transport failure (1/16)`, then crosses all three
  rollout/retention rounds. The run prints exact Registry snapshot-preservation success three
  times, enters the custom-image build, builds local image
  `sha256:fa365bd7edf8bfc7ea2696c43d6a91763bb693ef14031fd0eeea7a5a67acca7a` in
  **1,010.5 s**, reads registry manifest
  `sha256:f80d387f670c8f979e511ca828329b277d229e94bf98b4ac0177ac523daf5eb2`, and imports OCI
  manifest `sha256:71f4f3571492d237ad5c11ee6b62b3581bc17ac5da1550d8eee4cd9d166967cd` in
  **228.8 s**. Retention removes only superseded Registry manifest `d8c31a0e…` and local image
  `0d2766d2…`. Final Registry generation **8** is observed at 8 and `1/1`
  Ready/Available/Updated, zero restart. This is exact live closure of the fresh NodePort
  read-back counterexample.
- The corrected Provider sampler discards its initial wrong-kubeconfig/wrong-selector rows and
  restarts at `20:16:58Z`; all **295/295** retained rows observe the one Provider
  Pod/UID/image/limit identity Ready with zero restart. Peaks are **69,632 bytes** rootfs,
  **16,384 bytes** logs, **109,666,304 bytes** working set, **966,172 KiB** Pulumi home,
  **12 KiB** `/tmp`, zero `/dev/shm` and archive residue, and **114,364,416 bytes** cgroup memory
  under **1,174,405,120 bytes**; every memory-event counter remains zero. Percona generation
  **2** is `ready`, PostgreSQL `3/3`; all three newly suffixed member Pods are Ready/zero-restart
  and their claims bind exact retained ordinal PVs 0/1/2. The run terminates only on the
  already-registered `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`: Restore Delete
  Vscode fails, all four reconcile nodes and every other restore node succeed, Vault is
  initialized/unsealed, and the edge is `ready-for-external-proof`. The single permitted Target
  Agent log is empty; the single permitted Authority log records completed AWS-admin preparation
  and two `selected-agent/http-status/other` TLS failures. No other Kubernetes logs were read. No
  AWS Provider request or exact cleanup proof is reached. The Provider-response diagnostic,
  qualification, activation, preactivation, and writer cutover remain unproved.
- The repeated empty Target-Agent diagnostic plus Authority
  `selected-agent/http-status/other` result selects stable diagnostic counterexample
  `TLS-SELECTED-AGENT-ENDPOINT-RESPONSE-COLLAPSED-TO-HTTP-OTHER-2026-09-06` before any further TLS
  behavior change. Source enumeration proves the Target TLS endpoint itself authors a finite set
  of exact non-200 status/body pairs for prepare, retain, home-wrap, home-rewrap, restore, and
  verify, while `TlsTargetAgentClient` recognizes only the separate authenticated-role plaintext
  producer. Every exact endpoint semantic failure therefore collapses to `http-status/other`,
  indistinguishable from an arbitrary response; a successfully coordinated one-shot result such
  as verify missing or mismatch emits no standing coordinator-failure line. Add only a
  route-indexed, closed, payload-free classification of the endpoint-authored response pairs,
  preserve every public failure, request, authentication, replay, one-shot, Secret, and TLS
  behavior, validate locally, then rerun the exact targeted VS Code delete or `pre-1` to select
  the live branch. Exact cleanup, the Provider-response diagnostic, qualification, activation,
  preactivation, and writer cutover remain unproved.
- That behavior-neutral diagnostic is code-locally complete. The standing Target TLS handler now
  owns one finite source-of-truth algebra for every exact plaintext request-refusal,
  missing/mismatch, and one-shot-unavailable response across its six routes, and uses that same
  projection when emitting those responses. `TlsTargetAgentClient` classifies that endpoint
  projection before the separate authenticated-role projection, retains no body bytes, and
  renders only fixed `http-status/target/<route>/<cause>` tokens; arbitrary responses still
  collapse to `http-status/other`. Numeric status, public Authority failure, HTTP response,
  request, authentication, replay, worker, Secret, and TLS behavior are unchanged. The exact
  exhaustive regression passes **1/1 in 0.04 s**; restoring the collapsed arm makes it fail at
  the first endpoint response, after which the corrected source is restored byte-exactly.
  Complete local validation is green: canonical `prodbox dev check` passes with HLint `No hints`
  and warning-clean all-target compilation; installed unit passes **4,865/4,865** plus auxiliaries
  **27/27**, **35/35**, and **36/36**; installed `clean-room-handoff` passes; CLI integration
  passes **67/67 in 851.85 s** and environment integration passes **67/67 in 842.73 s**; `git
  diff --check` passes. The gate-built and synchronized executable is exact at
  `sha256:96f7285aac773cac00880a5e7aed2cffcfb328daaea07d4a7aba863327d3f93e`. Unchanged live
  selection is next; no deployment-qualification state changes yet.
- The unchanged diagnostic live `pre-1` replay runs from **17:51:40 through 18:36:08 EDT** with the
  corrected explicit Provider sampler using `/home/matthewnowak/.kube/config`; its command and
  evidence files are `PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE=pre-1 ./.build/prodbox test
  integration cascade-qualification --substrate aws`,
  `/tmp/prodbox-sprint-6.5-target-tls-response-diagnostic-live-pre-1.log`, and
  `/tmp/prodbox-sprint-6.5-target-tls-response-diagnostic-live-sampler.log`. It builds local image
  `sha256:ecca04f17d91930c4d32548a92f737309520921236458e629b92b5e52cbd4efc`, publishes Registry
  manifest `sha256:96bd9629b120f375818c63c249c7fa8c7498939ba109d8b7e25ea2acda6b9dc3`, and imports OCI
  manifest `sha256:d3730939c42403817a163cf8286cd03027337997add924ee0f75c65af559cb2a`. Both retained-home
  passes reuse exact root session `root-session-9c54db6a...`, baseline digest `a5756119...`,
  storage generation `vault-a290544e...`, and Lifecycle-provider credential generation **3**, and
  cross the control-plane, Gateway, TLS Retention, ZeroSSL, and shared-platform barriers.
- This live-closes
  `TLS-SELECTED-AGENT-ENDPOINT-RESPONSE-COLLAPSED-TO-HTTP-OTHER-2026-09-06`: the first VS Code
  delete failure remains public `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`, while the
  single permitted Authority log now selects exact
  `tls-retention/workflow failure=selected-agent/http-status/target/verify/mismatch`. Stable
  counterexample `TLS-RETENTION-VERIFY-MISMATCH-BEFORE-VSCODE-DELETE-2026-09-06` owns that first
  behavioral boundary. Prove which retained reference and current exact Secret observation
  diverge, and why, before changing verification, retention, version selection, certificate
  issuance, Secret lifecycle, or delete ordering. Because that refusal leaves VS Code undeleted,
  its later reconcile also fails publicly at selected-Agent unavailability; the permitted Target
  Agent log records exact
  `target-one-shot/tls-restore failure=coordinator/materialization-refused/tls-restore/secret-apply-failed/existing-content-mismatch`,
  and Authority records exact
  `selected-agent/http-status/target/restore/one-shot-operation-unavailable` followed by
  `adapter/http-status/replay-capacity-exhausted`. Those downstream results do not license a
  restore, replay-capacity, or Adapter change before the first verify mismatch is resolved.
- The total restore executor succeeds for both Gateway nodes, API, WebSocket, the Gateway MinIO
  bootstrap, and public-edge readiness, which finishes `ready-for-external-proof`; only VS Code
  delete and reconcile fail. The command exits **1**, exact cleanup is unproved, and operational
  credentials remain preserved. All **341** samples of the replacement Provider Pod name its exact
  image, **337** observe it Ready with zero restarts, and every complete cgroup-event observation
  is zero; its sampled cgroup memory peaks at **87,887,872 bytes** under the unchanged
  **1,174,405,120-byte** maximum. No Kubernetes logs other than the single permitted Target Agent
  and Lifecycle Authority reads were taken. The Provider-response diagnostic, qualification,
  activation, preactivation, and writer cutover remain unproved.
- Current-tree resumption validation on **2026-09-07** starts from a clean build of the exact
  repository revision. The synchronized executable is
  `sha256:6e09038a86248959e22471f0a62ce5cdd620eee70f1c3a589bea9cda15b898bc`, and canonical
  `prodbox dev check` exits **0** with HLint `No hints` and warning-clean all-target compilation.
  This refreshes only the code-local baseline: it does not close
  `TLS-RETENTION-VERIFY-MISMATCH-BEFORE-VSCODE-DELETE-2026-09-06`, prove cleanup, or change any
  qualification/cutover state. Rerun the exact live `pre-1` cycle next so the deployed closed
  verify-mismatch discriminator can select source identity, certificate identity, or both before
  any TLS behavior change.
- The exact live `pre-1` replay on that tree runs from **11:14:25 through 11:51:32 EDT** and stops
  before AWS setup, candidate execution, or TLS verification at the fresh-root Authority Backup
  readiness barrier. It builds local runtime image
  `sha256:82a41f292face9c2365cfb2abe05386f63b84a50747022d8d575f0ba1e695af9` in **983.2 s**,
  publishes Registry manifest
  `sha256:735c747f379cab2701c5bfc4c1a47747997bde25b27fa0b36a5e537414b90b91`, and imports OCI
  manifest `sha256:18a52c54354de0e3e25c9c3ddf158fb267a73e269d1a5d2656573e2b6ca85d31` in
  **127.5 s**. RKE2 `v1.36.4+rke2r1`, MinIO, Registry, Vault, Bootstrap Broker, Target Agent, and
  Lifecycle Authority reconcile on new storage generation `vault-8c9b826f...` and root session
  `root-session-28446425...`; the transcript is
  `/tmp/prodbox-sprint-6.5-current-tree-live-pre-1.log` at
  `sha256:22122b75619102f68d254496893f05d4f70b1a2eab544d09440b6756ddbaf0f4`.
- The terminal is exact: `chart_authority_backup` cannot satisfy `ProbeRolloutComplete` because
  `DeploymentAvailable "authority-backup" "authority-backup"` remains `False`. Read-only
  inspection proves the sole Pod pulled the exact runtime image, is Running with zero restarts,
  has a populated Service and EndpointSlice, emits no log line, and serves stable `HTTP 503` /
  `not-ready`. This is not the already-closed requested-revision rollout race; the Deployment is at
  revision 1 and the running process's dedicated-store readiness remains false on a newly
  initialized retained root. Stable counterexample
  `AUTHORITY-BACKUP-FRESH-ROOT-STORE-NOT-READY-2026-09-07` owns this earlier boundary. Add only a
  closed, value-free cause diagnostic to the dedicated-adapter readiness observer, prove it cannot
  render credential or provider detail, validate locally, and rerun the same live cycle before
  changing store, credential, bootstrap ordering, or retry semantics. No qualification artifact
  or activation witness exists, exact cleanup is unproved, and the legacy public writer remains
  sole.
- The value-free diagnostic requested by
  `AUTHORITY-BACKUP-FRESH-ROOT-STORE-NOT-READY-2026-09-07` is now code-local and validated. The
  dedicated-adapter transport returns the closed `DedicatedAdapterReadiness` algebra; its
  exhaustive eight-cause vocabulary renders only fixed tokens, and the Authority Backup / TLS
  Retention runtime readiness observers emit only store identity plus that fixed cause through the
  existing closed diagnostic sink. Adapter consumers retain the prior Boolean contract as a pure
  projection, so this revision changes observation only and does not change store, credential,
  bootstrap ordering, or retry behavior. The focused dedicated-adapter matrix passes **20/20** and
  canonical `prodbox dev check` passes with HLint `No hints` and a warning-clean all-target build.
  The synchronized executable is
  `sha256:a31e22557527ddb6e4c9d6d8909df70205076d517c26846cbaba3744a45f56ec`; the retained gate
  transcript is `/tmp/prodbox-sprint-6.5-diagnostic-dev-check.log` at
  `sha256:a2b29b57fd4fb253f1be5447d4a381739ce2d2f79c2cdc572cac1288d71a1cf0`. Rerun exact live
  `pre-1` next and require the closed cause before admitting any behavioral correction.
- The exact diagnostic `pre-1` rerun from **2026-09-07 12:31:23–12:56:16 EDT** reproduces the same
  pre-AWS `ProbeRolloutComplete` terminal and closes its cause: every Authority Backup readiness
  observation is the fixed `dedicated-adapter-readiness store=authority-backup-store
  cause=credential-unavailable` value. The sole revision-1 Pod is Running with zero restarts and
  the Service / EndpointSlice is populated, so the fresh-root cycle is exact: component admission
  waits for full Deployment availability before `StepEstablishAuthorityBackup` can create the
  credential that makes the process ready. The run builds local image
  `sha256:4112ad02742307dfcb1620cbb19df6e7732b88bf453ecff4a6bab3399d818585` in **992.0 s**,
  publishes Registry manifest
  `sha256:e25351e9723f971777450045291dbcfa3d4c806c9e2457f927005ae4fe3f411a`, and imports OCI
  manifest `sha256:18862373ae9d03cc90fbf06cb75e0fba19db75c274708113dca307a9ed2b8015` in
  **125.6 s**. Its transcript is `/tmp/prodbox-sprint-6.5-diagnostic-live-pre-1.log` at
  `sha256:8833cdb57cd871f5652ab65948f373e305b967d0acdef16fb2dae6835929a665`. Correct only
  this ordering: require the requested Deployment revision before establishment, then retain the
  full `DeploymentAvailable` barrier after credential establishment and in-force settings load.
  Pin both stages locally and rerun exact `pre-1`; no qualification artifact or activation witness
  exists, exact cleanup is unproved, and the legacy public writer remains sole.
- The fresh-root Authority Backup ordering correction is now code-local and validated. The
  `AuthorityBackupReadinessStage` algebra separates pre-establishment requested-revision
  convergence from post-establishment production availability.
  `StepAuthorityBackupRolloutReady` is a non-admitting `TransitionFor` step that performs the
  bounded revision observation directly; the component group's final `ComponentReadiness` remains
  after credential establishment, in-force config reconciliation, and settings reload and still
  requires both requested revision and `DeploymentAvailable`. The two focused stage/executor
  regressions pass **1/1** each, the primary unit suite passes **4873/4873**, the specialized
  Authority admission, authentication, and authenticated-transport suites pass **27/27**,
  **35/35**, and **36/36**, and canonical `prodbox dev check` passes with HLint `No hints` and a
  warning-clean all-target build. The synchronized executable is
  `sha256:92f1c4173fdf132046bccf1517d60d244042438f83a2181bf88a50298694f943`; the gate
  transcript is `/tmp/prodbox-sprint-6.5-authority-backup-ordering-dev-check.log` at
  `sha256:a1e9cfadb14b28f940e6dc78d623dc5b7e2f8d35e96b1cd44a8ad4d951f2b856`, and the
  canonical unit transcript is `/tmp/prodbox-sprint-6.5-authority-backup-ordering-unit.log` at
  `sha256:37080a99067b9a4f771409e3d561af0b24c1a89f53b439a8ab1119bf09ec7273`. Rerun exact
  live `pre-1` next; deployment qualification remains pending and the legacy writer remains sole.
- The ordering-corrected live `pre-1` from **2026-09-07 13:30:30–13:53:38 EDT** crosses the former
  Authority Backup rollout barrier and reaches Genesis credential establishment. It then exits 1
  on the protected worker terminal `execution-failed/install-requires-empty-inventory`; the
  coordinator correctly refuses the non-receipt as `AwsAdminWorkerReceiptDecodeFailed`. The run
  builds local image
  `sha256:ac9f61c0e6d8fe061fc54d0f50b7330539f2d7b183a820457185e5b2170e05e1` in **1004.0 s**,
  publishes Registry manifest
  `sha256:d204430fbe648878ca6347ed4ee2a057aa02f937ea005aca3503ee53e2567004`, and imports OCI
  manifest `sha256:07b5205c3f1da5472f553f69669dbd758408f46aeb8a20f5f7710e353f88671d` in
  **96.0 s**. Its transcript is
  `/tmp/prodbox-sprint-6.5-authority-backup-ordering-live-pre-1.log` at
  `sha256:383f694fd4029727d4aa4805f4b3ad3254ea6170e9703aad7fc8493f05d0fe17`.
  Stable counterexample `AUTHORITY-BACKUP-GENESIS-NONEMPTY-INVENTORY-2026-09-07` owns the next
  boundary. The exceptional Genesis permit already owns the deterministic backup identity and the
  execution journal already has a cleanup-required → stable-absence → one-remint path; admit that
  path only for an initial nonempty Genesis inventory. Preserve the ordinary-install refusal,
  require stable absence before the one fresh key creation, pin both decisions locally, and rerun
  exact `pre-1`. No qualification artifact or activation witness exists, exact cleanup is unproved,
  and the legacy public writer remains sole.
- That Genesis inventory counterexample is now closed code-locally. The AWS-admin execution fold
  uses an explicit install-attempt × observed-inventory decision: an empty inventory proceeds; a
  nonempty remint refuses because its single cleanup/remint budget is already spent; a nonempty initial
  `GenesisBackupKind` enters journaled cleanup-required, bounded deletion, stable-absence proof,
  and the one remint; and a plan-unbound ordinary or backup-repair initial install still refuses.
  No fresh key can be created before cleanup read-back. The readiness doctrine now also states the exact
  requested-revision → establishment-transport `/healthz` → post-establishment
  `DeploymentAvailable` order. Focused Genesis and retained cleanup-continuation proofs pass
  **1/1** each; canonical `prodbox dev check` passes with HLint `No hints` and warning-clean
  all-target compilation; the primary unit suite passes **4874/4874** and the Authority admission,
  authentication, and authenticated-transport suites pass **27/27**, **35/35**, and **36/36**. The
  synchronized executable is
  `sha256:376cba380f71b2ff1a3e70af8b64a8686a311e9dd466b4ddb76aac44f462042f`; the gate transcript is
  `/tmp/prodbox-sprint-6.5-genesis-inventory-dev-check.log` at
  `sha256:9aef1ee22642e7ce3ca5edb8947374648ef56cb943ad9fcf8ff5e5850f5f2b82`, and the unit transcript is
  `/tmp/prodbox-sprint-6.5-genesis-inventory-unit.log` at
  `sha256:5fffa8543c5537f116e3508c98d1046a9797c1db5b7e8a80add4842abd149473`. Rerun exact live
  `pre-1` next; deployment qualification remains pending and the legacy writer remains sole.
- The resulting live `pre-1` runs from **2026-09-07 14:34:14–14:58:37 EDT**, crosses the former
  nonempty-inventory refusal, and proves the execution decision reaches cleanup. It then exits 1
  on the protected terminal `execution-failed/journal-transition-rejected`: the journal permits
  cleanup-required from prepared-create and key-created phases, but not from the initial
  intent-committed phase selected by exceptional Genesis cleanup. The run builds local image
  `sha256:7dd679989f687da51b647e589f6e4a70011355e666dd8123364a8f06972e6e37` in **1008.6 s**,
  publishes Registry manifest
  `sha256:a15172a210a03c44b24d6c5778f8d10b223b52ad11fc1866fd53693f2cee964d`, imports OCI manifest
  `sha256:b036d3376926a67ec9bf6d7af543fff664423e0e431bab3838ad2cbaae4185ec` in **123.7 s**, and
  retains the exact root session `root-session-28446425...` and storage generation
  `vault-8c9b826f...`. Its transcript is
  `/tmp/prodbox-sprint-6.5-genesis-inventory-live-pre-1.log` at
  `sha256:babb84cfc2a5134f96382a76524bf9fa9a11f7892b0f18585ea49d71da5fc7d8`. Stable
  counterexample `AUTHORITY-BACKUP-GENESIS-INITIAL-CLEANUP-JOURNAL-TRANSITION-2026-09-07` owns
  the next boundary. Admit only `RequireAwsAdminStableCleanup False` from initial
  `GenesisBackupKind` intent; retain refusal for normal, backup-repair, remint-used, and mismatched
  flags, pin the journal transition and its negative space, then rerun exact `pre-1`. No candidate,
  qualification artifact, activation witness, or cleanup proof exists, and the legacy writer
  remains sole.
- The Genesis initial-cleanup journal counterexample is now closed code-locally. The journal
  inspects the signed permit and admits `RequireAwsAdminStableCleanup False` from
  `AwsAdminExecutionIntentCommitted False` only for `GenesisBackupKind`; normal and backup-repair
  permits, the spent-remint flag, and mismatched events remain refusals. Replayed cleanup-required
  is still idempotent. The execution decision now also refuses a nonempty remint with the existing
  closed `recovery-remint-ambiguous/intent-inventory-not-empty` cause instead of attempting a
  second cleanup. The inventory selector, exact journal edge, and retained cleanup-continuation
  focused proofs pass **1/1** each. Canonical `prodbox dev check` passes with HLint `No hints` and
  warning-clean all-target compilation; the primary unit suite passes **4874/4874**, with
  auxiliaries **27/27**, **35/35**, and **36/36**. The synchronized executable is
  `sha256:cd0ff240f8af9046fbf811dfca19f113d63880c70788f3cb49d73372f7366d00`; the gate transcript is
  `/tmp/prodbox-sprint-6.5-genesis-journal-dev-check.log` at
  `sha256:cbf9a4528a4bb5d511c9fd0a38bc59e898f50399c69a868c1f81e1bdb4f689ad`, and the unit transcript
  is `/tmp/prodbox-sprint-6.5-genesis-journal-unit.log` at
  `sha256:cc8470b7c06eca3252fef273316a1ede7e0c8d63a98ff22d477dcd9f339c6034`. Rerun exact live
  `pre-1` next; deployment qualification remains pending and the legacy writer remains sole.
- The next live `pre-1` runs from **2026-09-07 15:35:45–15:59:16 EDT** and live-closes the Genesis
  journal counterexample: the first AWS-admin attach contains one unique valid receipt, so
  exceptional Genesis cleanup, stable absence, remint, and Target delivery complete. The retained
  cursor then selects compiled member 1, `LifecycleProviderCredential`, and that first-reconcile
  install exits 1 on `execution-failed/install-requires-empty-inventory`. This is later than Genesis
  and before any candidate execution. The run builds local image
  `sha256:d9b50f3dd00153a5d5dff2c1a7d0a5152f8055bb0e25340793065b2926f50126` in **1004.5 s**,
  publishes Registry manifest
  `sha256:f2c5acbde5fc451930a26547b55d162cc10bb79bffffd0f5cdae39616d5f1e11`, imports OCI manifest
  `sha256:c327982c477c32286a281037cded12e2feb5c08530ce18179df2459ebfaf55c5` in **95.1 s**, and
  retains root session `root-session-28446425...` and storage generation `vault-8c9b826f...`. Its
  transcript is `/tmp/prodbox-sprint-6.5-genesis-journal-live-pre-1.log` at
  `sha256:6e24a5523b3b08b953bd2b35eccbc0b108ac976b91b41d9f2c9d47c34cd149f0`. Stable
  counterexample `FIRST-RECONCILE-DETERMINISTIC-IDENTITY-NONEMPTY-INVENTORY-2026-09-07` owns the
  next boundary. Extend initial cleanup authority only to a normal permit carrying an exact
  retained first-reconcile plan-member binding; keep post-first-reconcile normal installs, backup
  repair, remint-used, and mismatched bindings refused, require stable absence before the single
  remint, pin the positive and negative journal/decision cases, and rerun exact `pre-1`. No
  candidate, qualification artifact, activation witness, or exact cleanup proof exists, and the
  legacy writer remains sole.
- That first-reconcile inventory counterexample is now closed code-locally. The install fold
  carries an explicit signed-intent plan-binding classification and admits initial cleanup for
  nonempty inventory only for Genesis or normal operator material bound to an exact retained
  first-reconcile plan member. A plan-unbound normal install, backup repair, and every remint-used
  nonempty inventory remain closed refusals. The execution journal independently inspects the
  signed permit before admitting the one initial cleanup transition, so stable absence still
  precedes the only fresh-key creation. The stable-counterexample focus is **2/2**, the retained
  cleanup-continuation proof is **1/1**, canonical `prodbox dev check` is clean, and the full unit
  boundary is **4,874 + 27 + 35 + 36** passing tests. The exact executable is
  `sha256:8e3687988911909bafa84b5bf55064f015c6c417a75a57e6bc4a59df80d01115`; the gate
  transcript is `/tmp/prodbox-sprint-6.5-first-reconcile-inventory-dev-check.log` at
  `sha256:cbf9a4528a4bb5d511c9fd0a38bc59e898f50399c69a868c1f81e1bdb4f689ad`, and the unit
  transcript is `/tmp/prodbox-sprint-6.5-first-reconcile-inventory-unit.log` at
  `sha256:a302606144c82e452aa4fb76f85bff8eb62b6c70162f5f14e9aa55d629baaaa0`. Exact
  `pre-1` is again the next action. No candidate, qualification artifact, activation witness, or
  exact cleanup proof exists, and the legacy writer remains sole.
- The exact live `pre-1` rerun proves that counterexample across all five compiled
  first-reconcile members: each deterministic identity traverses cleanup/recovery, the
  Lifecycle-provider credential reads back current at generation **2**, and the run completes the
  home platform reconcile through DNS01/EAB materialization and a Ready ZeroSSL issuer. It builds
  local image `sha256:21848a1ea426f39319f9aaaeca26025a9789e22fd0b11810416d4904e84a6e80`
  in **1001.7 s**, publishes Registry manifest
  `sha256:72b901029af68a32331b1f4a475961469bd6dee67562d3d395103cb0b78212d1`, and imports OCI
  manifest `sha256:f0f783d10ed1415cb40c5e9685e368ef107a497200dbb3aa864aafe1637806df`
  in **121.5 s**. Candidate execution then reaches the chart-deletion graph and stops at
  `TlsRetentionWorkflowAuthoritySourceReadBackMismatch`. Its failure wrapper restores a public
  edge classified `ready-for-external-proof`, but reports one failed best-effort VS Code deletion
  and explicitly does **not** prove exact terminal cleanup, so it preserves operational
  credentials for recovery. The transcript is
  `/tmp/prodbox-sprint-6.5-first-reconcile-inventory-live-pre-1.log` at
  `sha256:d847ccaa70d625823886db970157e1a5d4108a677e346a2e77ca97e513904f2b`. Stable
  counterexample `TLS-RETENTION-AUTHORITY-SOURCE-READBACK-MISMATCH-2026-09-07` owns the next
  boundary: isolate the exact retained source/operation binding that disagrees at Authority
  read-back, pin the positive and mismatch cases at that ownership boundary, preserve the closed
  refusal, and rerun exact `pre-1`. No candidate qualification artifact, activation witness, or
  exact cleanup proof exists, and the legacy writer remains sole.
- Read-only retained-Authority diagnosis selects the narrower internal cause
  `tls-retention/workflow failure=legacy-source-missing`; the later retain-on-ready attempt is an
  independent `home-agent/http-status/target/home-rewrap/one-shot-operation-unavailable`. The
  selected-Agent protocol assigns 404 only to an exact missing Secret/restore slot, while an
  unobservable read is 503 and a source/content disagreement is 409. The partial-state topology is
  therefore exact: a fresh Authority TLS aggregate sees the pre-outbox immutable Adapter version,
  the `vscode` namespace exists, and legacy adoption finds no selected source Secret before the VS
  Code delete. Preserve the workflow-level refusal and append one payload-free
  `LegacySourceMissing` Authority failure arm without renumbering existing wire constructors. Only
  the chart pre-delete fold may consume that exact arm, after its existing exact namespace/access
  proof, by running the existing Certificate presence classifier: present means explicitly
  deferred issuance; absent means explicitly nothing to retain. Adapter/source mismatch, corrupt
  occupation, unobservable access, and every other Authority refusal remain terminal;
  retain-on-ready also keeps an exact missing source terminal because readiness and absence
  disagree. Pin the new projection, both classifier outcomes, and the negative
  mismatch/unavailable space before exact `pre-1`.
- That partial-state TLS counterexample is now closed code-locally. The Authority workflow appends
  the payload-free `TlsRetentionWorkflowAuthorityLegacySourceMissing` constructor and maps only
  `TlsWorkflowLegacySourceMissing` to it; direct source mismatch and non-idempotent adoption retain
  the prior source-mismatch refusal. `PublicEdgeTlsRetainResult` keeps this arm typed on both home
  and AWS paths. Only VS Code pre-delete feeds it into the existing exact Certificate classifier,
  while retain-on-ready converts it to a terminal inconsistency. The stable-counterexample proof is
  **1/1**, the complete TLS endpoint group is **30/30**, the public-edge preserve group is **5/5**,
  canonical `prodbox dev check` is clean, and the full unit boundary is **4,875 + 27 + 35 + 36**
  passing tests. The exact executable is
  `sha256:17b677543d076a266518593b1aec0981beda7c80c28954f57b14e12c34f35c03`; the focused
  transcript is `/tmp/prodbox-sprint-6.5-tls-legacy-source-focused.log` at
  `sha256:b710045bda7c96ceca5bd9e9a68dc33747083788b45c2e3bf59f164fca5f331e`, the gate
  transcript is `/tmp/prodbox-sprint-6.5-tls-legacy-source-dev-check.log` at
  `sha256:02eb7d91be76658bb356f24186daef4742a2271705421e2d8f247f7fbf5912ab`, and the
  unit transcript is `/tmp/prodbox-sprint-6.5-tls-legacy-source-unit.log` at
  `sha256:c541c2c649698b7e9cfca1510fad5e2103b5c3029ba00cddf6a0e394bd30caa9`. Exact
  `pre-1` is again the next action. No candidate qualification artifact, activation witness, or
  exact cleanup proof exists, and the legacy writer remains sole.
- The exact same live `pre-1` rerun starts platform reconciliation at **2026-09-07 18:03:52 EDT**
  and exits at **18:28:46 EDT**, before candidate execution, after
  `ConfigBackupTransportFailed (AuthenticatedClientTransportFailed
  (ControlPlaneTransportFailed (HttpTimeout "connection timeout")))` makes the retained in-force
  config unobservable. It builds local image
  `sha256:e083cbc339c5aaf933dcc23a9be5eac80f0a37ff9946e23ec291c94750e0eecd` in
  **1129.3 s**, publishes Registry manifest
  `sha256:4e249014c7189914d04b77b11aa73d4812fd94d997d7168a7980861104200421`, and imports OCI
  manifest `sha256:9949ced000e851393d9ed6ad2056fa827f5ae8e0202442327174a6ada7a71fa0`
  in **90.9 s**. Its transcript is
  `/tmp/prodbox-sprint-6.5-tls-legacy-source-live-pre-1.log` at
  `sha256:b91175116282d34ec95c07fb6af388410e301ed51c857fb63f445750b0af5488`.
  Read-only Kubernetes timing makes the race exact: the new Lifecycle Authority Pod starts at
  22:28:18Z and is Ready at 22:28:29Z; the Recreate Authority Backup Pod starts at 22:28:33Z, is
  reachable through the Pod-local establishment transport, but does not become Ready and enter its
  Service EndpointSlice until 22:28:44Z. The Lifecycle Authority config observation enters that
  empty-Service interval and the transcript closes two seconds after routing becomes available.
  Stable counterexample `AUTHORITY-BACKUP-POST-ESTABLISHMENT-SERVICE-ROUTING-2026-09-07` owns this
  boundary. Add a non-admitting post-establishment requested-revision-plus-Deployment-availability
  barrier before config observation, retain the graph-owned production admission after in-force
  settings load, pin the positive ordering and pre-establishment negative space, and rerun exact
  `pre-1`. No candidate, qualification artifact, activation witness, or exact cleanup proof exists,
  and the legacy public writer remains sole.
- That Service-routing counterexample is now closed code-locally. The native Authority Backup
  component has three explicit stages: pre-establishment revision convergence without
  availability, post-establishment Service routing with requested revision plus
  `DeploymentAvailable`, and the same full observation again as graph-owned production admission
  after settings load. The new `StepAuthorityBackupServiceRoutingReady` is a non-admitting
  transition placed between successful establishment and the first in-force config observation,
  and both rendered reconcile plans expose that exact order. The stable-counterexample proof
  passes **1/1**, the two changed golden plans pass **1/1** each, canonical `prodbox dev check` is
  clean, and the full unit boundary is **4,876 + 27 + 35 + 36** passing tests. The exact executable
  is `sha256:0e5c9d72badced7a2cf3e80a428ad6d1f897a98d57933a750d5339b5db5ece9c`; the focused
  transcript is `/tmp/prodbox-sprint-6.5-authority-backup-service-routing-focused.log` at
  `sha256:9f56d8e13b32495e3f02f5893b23b5ec95abff2aa7795a8f57f7e5fcf7dd0c62`, the gate
  transcript is `/tmp/prodbox-sprint-6.5-authority-backup-service-routing-dev-check.log` at
  `sha256:0a8ecf3f50878be0360d3682606acc2c099c0dbc03bc49908706cd2a36ffad6f`, and the unit
  transcript is `/tmp/prodbox-sprint-6.5-authority-backup-service-routing-unit.log` at
  `sha256:6a8d0a88f5a8c15c4c060a016d16745276b819049dc382b4d604b39f67de8ae5`. Exact `pre-1`
  is again the next action. No candidate, qualification artifact, activation witness, or exact
  cleanup proof exists, and the legacy public writer remains sole.
- The exact live `pre-1` rerun starts platform reconciliation at **2026-09-07 19:20:25 EDT** and
  exits 1 at **20:02:39 EDT** after the full AWS harness restoration wrapper. It builds local image
  `sha256:57ab819f57372dcce054eed4f6197bd18d1f3372669a9e9d27c9d8d76dcec025` in
  **1131.0 s**, publishes Registry manifest
  `sha256:c34972ec740db08305b192935abbc1163a58c130341f7a99fca85434d2c01f4b`, and imports OCI
  manifest `sha256:cb1aacd72362a104b02115c7c3ed88ba789980bb9262fdf03d7a98cc2be0f069`
  in **90.1 s**. Its transcript is
  `/tmp/prodbox-sprint-6.5-authority-backup-service-routing-live-pre-1.log` at
  `sha256:b3dd7c467a874320c488d88f0863f59a8d5a27bdd0b30a897eb64f0876e51ff1`.
  The run crosses the new Authority Backup Service-routing barrier, reads the retained config and
  marker current, reaches Lifecycle-provider credential generation 2, and completes home-platform
  reconcile. It also live-proves the missing-legacy-source TLS correction: websocket and API
  pre-delete both classify the absent source as nothing to preserve and continue. VS Code
  pre-delete then fails at `TlsRetentionWorkflowAuthorityHomeAgentUnavailable`; the protected
  Authority log narrows that to
  `home-agent/http-status/target/home-rewrap/one-shot-operation-unavailable`, while the Target
  Agent log currently collapses the one-shot failure to
  `target-one-shot/tls-home-rewrap failure=coordinator/materialization-refused`. Stable
  counterexample `TLS-HOME-REWRAP-TARGET-MATERIALIZATION-REFUSED-2026-09-07` owns this diagnostic
  boundary. Add only a closed, value-free home-rewrap runtime refusal classification, pin its
  finite causes and arbitrary-detail collapse, then rerun exact `pre-1` before changing behavior.
  The wrapper restores gateway, VS Code, API, websocket, and the Ready public edge, but exact
  terminal cleanup is not proved, so operational credentials remain preserved. No candidate
  qualification artifact or activation witness exists, and the legacy public writer remains sole.
- That diagnostic boundary is now closed code-locally. Home rewrap maps its two runtime result
  arms to `TargetSecretWorkerTlsHomeRewrapFailed` or
  `TargetSecretWorkerTlsHomeRewrapBadRequest`; the value-free renderer erases nested exchange and
  codec values to `tls-home-rewrap/dek-exchange-failed` or
  `tls-home-rewrap/bad-request`. The standing Target Agent admits only those two exact additions
  and still maps arbitrary detail to `materialization-refused/other`. Worker execution, protocol,
  authentication, session and Job cleanup, retry, HTTP behavior, and TLS decisions are unchanged.
  The exhaustive focused regression passes **1/1**, canonical `prodbox dev check` is clean, and
  the full unit boundary remains **4,876 + 27 + 35 + 36** passing tests. The exact executable is
  `sha256:46b7d55fcc3a5420303115345c45c59d86f5acde455515fbd827ec81a165f835`; the focused
  transcript is `/tmp/prodbox-sprint-6.5-tls-home-rewrap-diagnostic-focused.log` at
  `sha256:496858316941fe2207fd91f31a07abcec3ee992f20dc495c12c78d929cf5dddc`, the gate
  transcript is `/tmp/prodbox-sprint-6.5-tls-home-rewrap-diagnostic-dev-check.log` at
  `sha256:9d8c8247d45463623807b6cae68515d58f8eb9fd1e3901ad538c564de339879b`, and the unit
  transcript is `/tmp/prodbox-sprint-6.5-tls-home-rewrap-diagnostic-unit.log` at
  `sha256:42da6d4f4b4ad5e516aec4b98e57d9b9077bb5192a57b571e546407e615cbe93`. Exact
  `pre-1` is again the next action. No candidate qualification artifact, activation witness, or
  exact cleanup proof exists, and the legacy public writer remains sole.
- The unchanged diagnostic live `pre-1` closes at **2026-09-07 21:18:26 EDT** with transcript
  `/tmp/prodbox-sprint-6.5-tls-home-rewrap-diagnostic-live-pre-1.log` at
  `sha256:042e5e3a1d63d25f7160c36c7e8bc0caea1e6ef3a73bba94001336582da0340f`. It builds
  local image `sha256:e9050236f267687495ab61c1861eb87088f51d3c2c820fc21a76f46eea1d40f4`
  in **1131.9 s**, publishes Registry manifest
  `sha256:905073cad62d9a494bf13be9a73107bc707c92fe5cfde751dd74385331596c8a`, and imports OCI
  manifest `sha256:39f7f63f489a00fbf5d10776d67bbf82fa7a65e2b3f6481c3455600b954ea022`
  in **99.6 s**; retention removes only the immediately preceding manifest and local image. It
  again crosses retained config, marker, credential generation 2, home-platform reconcile, and
  the missing-source websocket/API deletion paths. The new protected Target Agent diagnostic
  selects exact `materialization-refused/tls-home-rewrap/dek-exchange-failed`; Authority preserves
  the outer `home-agent/http-status/target/home-rewrap/one-shot-operation-unavailable`. Stable
  successor counterexample `TLS-HOME-REWRAP-DEK-EXCHANGE-FAILED-2026-09-07` owns the
  still-collapsed finite `TlsDekExchangeError` boundary. Refine only that closed value-free error
  projection and its allowlist, then rerun exact `pre-1` before changing Transit policy,
  ciphertext, key material, or effect behavior. The total wrapper again restores every runtime
  node except the VS Code delete, and the final public edge is `ready-for-external-proof`; exact
  terminal cleanup is nevertheless unproved, operational credentials remain preserved, no
  candidate artifact or activation witness exists, and the legacy public writer remains sole.
- That successor diagnostic is now closed code-locally. An exhaustive bounded
  `TlsDekExchangeRefusalCause` projects all eleven `TlsDekExchangeError` constructors without
  their length, version, cipher, Transit, or nested error values. Home-rewrap refusals admit only
  those generated `dek-exchange-failed/<cause>` tokens plus exact bad-request and defensive
  other-target arms; arbitrary detail still collapses to `materialization-refused/other`. The
  projection and allowlist cardinality regression passes **1/1**, canonical `prodbox dev check` is
  clean, and the full unit boundary remains **4,876 + 27 + 35 + 36** passing tests. The exact
  executable is
  `sha256:1ce82b18f37fa169d339fc11df40482971662859ec21c64c08c2d4efe12e38d3`; the focused
  transcript is `/tmp/prodbox-sprint-6.5-tls-home-rewrap-exchange-diagnostic-focused.log` at
  `sha256:496858316941fe2207fd91f31a07abcec3ee992f20dc495c12c78d929cf5dddc`, the gate
  transcript is `/tmp/prodbox-sprint-6.5-tls-home-rewrap-exchange-diagnostic-dev-check.log` at
  `sha256:01f2d502e24680b4cc92239303e8d2b2eea0611e5e08a285ba1afd24a02bb4f2`, and the unit
  transcript is `/tmp/prodbox-sprint-6.5-tls-home-rewrap-exchange-diagnostic-unit.log` at
  `sha256:243640e2bb2ce18b7dd1d109c6f8ef810edf1fa810b997a02913685055093eaa`. No TLS effect,
  policy, authentication, retry, or cleanup behavior changes. Exact `pre-1` is again the next
  action; no candidate artifact, activation witness, or exact cleanup proof exists, and the legacy
  public writer remains sole.
- The exact diagnostic live `pre-1` runs from **2026-09-07 21:49:46–22:32:47 EDT** and selects the
  closed successor
  `materialization-refused/tls-home-rewrap/dek-exchange-failed/transit-unwrap-unavailable` in the
  protected Target Agent log. The Authority-facing projection remains
  `home-agent/http-status/target/home-rewrap/one-shot-operation-unavailable`. It builds local image
  `sha256:7d874db465aa63d4e48d5f0189bace5e29114098fa2a6e70f120a8cff3f58f38` in
  **1134.5 s**, publishes Registry manifest
  `sha256:e01f38b7ce72b9ca4f2687370c7461426009511d6b1bcb6668afe7848ee755a0`, and imports OCI
  manifest `sha256:73edd1ac3397ce369ecf685b008132c1006a137e2b61cbedae3c208bdbfb3f6f`
  in **89.5 s**; retention removes only the immediately preceding manifest and local image. The
  run crosses retained config and marker observation, Lifecycle-provider credential generation 2,
  home platform reconcile, and the websocket/API missing-source deletion paths before VS Code
  deletion requests the retained-home DEK unwrap. Its total wrapper restores all runtime nodes,
  with only the repeated best-effort VS Code deletion failed, and returns the public edge to
  `ready-for-external-proof`; exact terminal cleanup is not proved and operational credentials
  stay preserved. The transcript is
  `/tmp/prodbox-sprint-6.5-tls-home-rewrap-exchange-diagnostic-live-pre-1.log` at
  `sha256:1e0b24c450364c31062a8db5992afead917d14dcfe5ab13f56518017b9f024df`. Stable
  counterexample `TLS-HOME-REWRAP-TRANSIT-UNWRAP-UNAVAILABLE-2026-09-07` owns the next boundary:
  classify the value-free Transit failure at the authenticated Vault boundary before changing
  policy, ciphertext, key material, retry, or effect behavior, pin every admitted diagnostic and
  arbitrary-detail collapse, and rerun exact `pre-1`. No candidate artifact, activation witness,
  or exact cleanup proof exists, and the legacy public writer remains sole.
- That Transit diagnostic boundary is now closed code-locally. `TlsDekTransitBoundary` returns an
  exhaustive value-free `TlsDekTransitFailure`; the production Vault seam uses detailed
  authenticated session provenance and classifies acquisition, relogin, exact common request
  statuses, other client/server/status classes, connection, timeout, decode, and unexpected
  exceptions without retaining any detail. `TlsDekTransitUnwrapUnavailable` carries that cause
  through the exchange, and the protected Target-worker allowlist is generated from the finite
  type. The stable-counterexample focus, including exact cause propagation, exhaustive projection,
  allowlist cardinality, and arbitrary-detail erasure, is **1/1**; canonical `prodbox dev check` is
  clean, and the full unit boundary remains **4,876 + 27 + 35 + 36** passing tests. The exact
  executable is
  `sha256:91b646318789d4df24e20845e50c68ba0efb557df81aaa00c07285a49e443067`; the focused
  transcript is `/tmp/prodbox-sprint-6.5-tls-transit-diagnostic-focused.log` at
  `sha256:16f49269d0c3c4dc61b2775d01b00b4d20e80dac40f6660725c459c697eb8153`, the gate
  transcript is `/tmp/prodbox-sprint-6.5-tls-transit-diagnostic-dev-check.log` at
  `sha256:d8d26986f7800c81aac810ff1951bd14ab9126e1f87c6e9f611639dbae0c5091`, and the unit
  transcript is `/tmp/prodbox-sprint-6.5-tls-transit-diagnostic-unit.log` at
  `sha256:a079f516c079649a3765ce432e7085c721a7fe6c18fcf31bf5fdf3ff4e6ecff4`. No policy,
  ciphertext, key-material, retry, authentication, effect, or cleanup behavior changes. Exact
  `pre-1` is again the next action; no candidate artifact, activation witness, or exact cleanup
  proof exists, and the legacy public writer remains sole.
- The exact diagnostic live `pre-1` runs from **2026-09-07 23:14:24–23:57:53 EDT** and selects
  `materialization-refused/tls-home-rewrap/dek-exchange-failed/transit-unwrap-unavailable/request-bad-request`
  twice in the protected Target Agent log. This proves an authenticated Vault request returning
  HTTP 400 after session handling; it rules out session acquisition/relogin, permission,
  throttling, server, transport, timeout, and response-decode classes while leaving the closed
  Vault bad-request families unresolved. The
  Authority-facing projection remains
  `home-agent/http-status/target/home-rewrap/one-shot-operation-unavailable`. The run builds local
  image `sha256:cee5e84d6a2510621ade27540e44b67d5d08f0d185d0f39a774c333f59eec62d`
  in **1130.2 s**, publishes Registry manifest
  `sha256:f8e3b3779da1b8c23627d076d5c9f21e0458dcc849746b0444a0839d69d80a90`, and imports OCI
  manifest `sha256:d6950a1b262b64dcb42ff406e179b958fa4093bf806c044b7ce71ca37bbd4d6d`
  in **92.3 s**; retention removes only the immediately preceding manifest and local image. It
  again crosses retained config, marker, credential generation 2, complete home-platform
  reconcile, and the websocket/API missing-source deletion paths. The total wrapper restores every
  runtime node; only the repeated best-effort VS Code deletion fails. Its first public-edge
  observation sees transient missing DNS, the bounded retry observes Route 53 in sync, and the
  final classification is `ready-for-external-proof`. Exact terminal cleanup is nevertheless
  unproved and operational credentials stay preserved. The transcript is
  `/tmp/prodbox-sprint-6.5-tls-transit-diagnostic-live-pre-1.log` at
  `sha256:8809debfa722002f75c631bb25af107dc36431639916c3bb7bdc56e60e6900a7`. Stable
  counterexample `TLS-HOME-REWRAP-TRANSIT-BAD-REQUEST-2026-09-07` owns the next boundary: prove the
  retained wrapped-DEK/key provenance that makes Vault reject this exact ciphertext before
  changing the key, ciphertext, or retention state; pin recovery and every mismatch/refusal case,
  then rerun exact `pre-1`. No candidate artifact, activation witness, or exact cleanup proof
  exists, and the legacy public writer remains sole.
- The stable counterexample's bad-request diagnostic is now closed code-locally without changing
  a Transit effect or recovery decision. The production boundary decodes only Vault's canonical
  singleton `errors` response and maps the pinned Vault `1.18.3` decrypt grammar onto twelve
  finite, value-free causes: missing ciphertext, key not found, five malformed/version-invalid
  ciphertext families, policy-too-old ciphertext, invalid convergent nonce, invalid ciphertext
  length, AEAD authentication failure, or `other`. Malformed, multi-error, and unknown bodies all
  collapse to `request-bad-request/other`; no body or server detail enters the exchange state,
  allowlist, or protected diagnostic. The exhaustive renderer/allowlist and classifier regression
  passes **1/1**, including every recognized response and arbitrary-detail erasure, and the
  complete unit boundary passes **4,876 + 27 + 35 + 36**. The exact executable is
  `sha256:c3d8c61b1fce670df99c5ad20196f8114cd03bef777ef7437ee1485416c73bab`; the focused
  transcript is `/tmp/prodbox-sprint-6.5-tls-transit-bad-request-focused.log` at
  `sha256:496858316941fe2207fd91f31a07abcec3ee992f20dc495c12c78d929cf5dddc`, and the unit
  transcript is `/tmp/prodbox-sprint-6.5-tls-transit-bad-request-unit.log` at
  `sha256:4becdd5d0c5c8b4aea854853b2480896b286272876538b6fa7a3da395a61ef03`. Canonical
  `prodbox dev check` passes on this documentation-inclusive revision; its transcript is
  `/tmp/prodbox-sprint-6.5-tls-transit-bad-request-dev-check.log` at
  `sha256:c8aa82d9ed48f7bf839410c3eae965a29b10db5839d7134587ec657a3f9660f5`. Exact live
  `pre-1` is the next action. No candidate artifact, activation witness, or exact cleanup proof
  exists, and the legacy public writer remains sole.
- The exact refined live `pre-1` runs from **2026-09-08 00:38:11–01:21:25 EDT** and selects
  `materialization-refused/tls-home-rewrap/dek-exchange-failed/transit-unwrap-unavailable/request-bad-request/ciphertext-authentication-failed`
  twice in the protected Target Agent log. Vault therefore accepted the ciphertext grammar and
  version but the AEAD tag did not authenticate under the current retained-home Transit key; this
  rules out missing-key, malformed-ciphertext, version-too-new, policy-too-old, and all non-400
  families without exposing ciphertext or response detail. The Authority keeps the expected outer
  `home-agent/http-status/target/home-rewrap/one-shot-operation-unavailable`, and the CLI keeps
  `TlsRetentionWorkflowAuthorityHomeAgentUnavailable`. It builds local image
  `sha256:69f9029f668a417517afd1fc3e79151198297045f1b60c1867ab08575650a3bb` in **1117.0 s**,
  publishes Registry manifest
  `sha256:71d1133bb699b251809f1153428f5ad73ea5904875548b8c11018e9cbe1cabeb`, and imports OCI
  manifest `sha256:ee5a30b10afb24e2182f423185f7f21a5546de1436cdcf8c114d359662f6cffc`
  in **90.1 s**; retention removes only the preceding Registry manifest and local image. The run
  crosses retained config and marker observation, Lifecycle-provider credential generation 2, the
  complete home-platform reconcile, and websocket/API missing-source deletion before VS Code
  deletion asks the home Agent to unwrap the retained DEK. The total wrapper restores all runtime
  nodes, the final public edge is `ready-for-external-proof`, and a complete cluster inventory
  shows no Target one-shot or Credential Provisioner Job/Pod residue. Exact terminal cleanup is
  still unproved and operational credentials remain preserved. The transcript is
  `/tmp/prodbox-sprint-6.5-tls-transit-bad-request-live-pre-1.log` at
  `sha256:d463061e2f8373527d860268c456022fb9ce97c2f4aac5c545b7b64664c49e78`.
  Stable successor counterexample
  `TLS-HOME-REWRAP-TRANSIT-CIPHERTEXT-AUTHENTICATION-FAILED-2026-09-08` now owns the exact
  retained-provenance boundary. Prove whether the occupied immutable TLS version and its
  Authority/current-or-pending record are bound to the current Vault storage generation and
  Transit key generation, then pin recovery for every absent, mismatched, and unobservable
  provenance case before changing any retention decision or allocating another version. No
  candidate qualification artifact, activation witness, or exact cleanup proof exists, and the
  legacy public writer remains sole.
- That retained-provenance counterexample is closed code-locally by one narrow, crash-safe
  pre-outbox transition. Historical evidence binds the occupied version-1 envelope to retained-home
  Vault storage generation
  `vault-a290544ececcff87892b19c03dcbf1a06ad3eb800614aaf413af5b81f42ad422`; the current
  generation is
  `vault-8c9b826f8837e83494e164d06e30a79966669b52d6d09f6511d63182c335146a`, its Authority TLS
  aggregate is empty, and the exact current Kubernetes source remains present. Only the authenticated
  Target result `home-rewrap-ciphertext-authentication-failed` selects recovery after normal
  version-1 decrypt/apply fails. The workflow encrypts the current source afresh as fixed version 2,
  then one Authority CAS records the abandoned version-1 envelope digest together with the complete
  version-2 pending outbox before the immutable PUT. Recovery-pending has no current/predecessor
  reference, so restore and issuance refuse; exact replay resumes the same v2 bytes, and ordinary
  Adapter read-back plus source re-observation must precede promotion. Nonempty or pending Authority
  state, wrong version, invalid or changed digest, mismatched candidate/envelope, missing source,
  every other Target/Vault result, and every unobservable arm refuse. Version 1 is never applied,
  promoted, overwritten, deleted, listed, or selected as latest.
- The exact cause crosses the one-shot worker, standing Target endpoint, and authenticated client as
  an appended value-free constructor; arbitrary status/body text remains erased. The separate
  authenticated Authority recovery-staging route is additive at numeric code **63**, preserves all
  preceding wire tags, and is reachable only inside the Authority-owned TLS workflow. The added
  recovery calls widen one complete Target attempt from 29 to **32** requests and its two-attempt
  retained replay from 58 to **64** entries with a **130 MiB** encoded ceiling. Focused workflow,
  worker, route, and transport suites pass **31/31**, **41/41**, **9/9**, and **36/36** at
  `/tmp/prodbox-sprint-6.5-tls-legacy-recovery-{workflow-focused,worker-focused,route-focused,transport-focused}.log`
  with respective SHA-256 digests
  `b6aafe8d72528b8e8a3f916d6c64c92bcea72360f3072407c8145fc0039f00f3`,
  `620fa194db1e734ff378a8168f5cccef9f9842f92fe0457e94afeb3ae754af44`,
  `bdda6b0d9dde418184405e1a5c8926a4abb6374beec0a7433082ec96fec90ddd`, and
  `4ae5db907fbd3bd1041566d6082f55dc4d0174c22161359e287cdbae9c2240c0`.
  Canonical unit validation passes **4,880 + 27 + 35 + 36**; its transcript is
  `/tmp/prodbox-sprint-6.5-tls-legacy-recovery-unit.log` at
  `sha256:c936fc446df7223dd0741aec2cfb01d5601b1457463f245c8502d1ebad8bc2ee`.
  Canonical `prodbox dev check` passes on the doctrine-inclusive recovery revision at
  `/tmp/prodbox-sprint-6.5-tls-legacy-recovery-dev-check.log`,
  `sha256:e3840dd900a3ceba09fa5ca7313dd8d58f56c90b15a3b01212b99acff5536b81`; the synchronized
  executable is `sha256:4b4b0c4621bd409f908959258ff87ce62f4d2799873ce5e9120f06caf6b6ca1b`.
  Exact live `pre-1` is next. No candidate qualification artifact, activation witness, or exact
  cleanup proof exists, and the legacy public writer remains sole.
- The exact replay-compatible live `pre-1` runs from **2026-09-08 04:20:39–05:02:46 EDT**. It
  builds local image `sha256:32d7dd7266affee1305b2e7bf36cfb7dc0fc2eb07be06441be160ff50633283d` in **1,113.2 s**,
  publishes Registry manifest
  `sha256:560ff6c3c41bdc76b0e097b3dd6dfcc5b9dfafd5f810aabc39fe2ae48b104330`, and imports OCI
  manifest `sha256:381423488a4a929659faf1fd6ea0e4bd589b1db4942e78dc278bdf8c9907bd741` in **89.1 s**.
  Retention removes only the immediately superseded manifest/image. The Target Agent becomes
  Ready, live-proving canonical nonempty v9/capacity-58 admission under v10/capacity 64. The TLS
  workflow then durably stages recovery version 2 but the immutable exact key is already occupied
  by different canonical bytes; the protected Agent selects
  `adapter/http-status/store/repository-failed/put/conflict/confirmation/bytes-mismatch`, and
  restore subsequently selects `pending-without-current`. Stable counterexample
  `TLS-LEGACY-RECOVERY-V2-IMMUTABLE-COLLISION-2026-09-08` owns this exact boundary. Its repair may
  rebase only a legacy-recovery pending outbox after that closed conflict onto exact-key-observed
  canonical bytes with identical legacy evidence, approval, version, certificate, and source; it
  must retain the recovery-pending restore/issuance refusal and require the ordinary adapter
  read-back plus source re-observation before promotion. The wrapper restores the public edge to
  `ready-for-external-proof`; VS Code restore remains the repeated best-effort failure, exact
  cleanup is unproved, and operational credentials remain preserved. The transcript is
  `/tmp/prodbox-sprint-6.5-target-replay-v9-widen-live-pre-1.log` at
  `sha256:9d9c38051a853b2be0c3b504f23d6d1f88cb82bdd4e2163f3c1393a3fcb9f5ab`. No candidate
  qualification artifact or activation witness exists, and the legacy public writer remains sole.
- That immutable-collision counterexample is now closed on the code-owned surface without deleting,
  overwriting, or selecting a latest retained object. The Authority can append one exact
  legacy-recovery collision outbox only from the ordinary recovery-pending state and only after the
  Target Agent reports the closed exact-key `put/conflict/confirmation/bytes-mismatch` outcome. The
  request durably binds the original pending digest and exact-key-observed digest; approval,
  version, certificate, source, and legacy-v1 evidence must remain identical, while the two
  envelope digests must be distinct. The workflow re-applies only the observed canonical envelope
  through retained-home rewrap, re-observes its source, commits the collision outbox by CAS, and
  then uses the ordinary exact store read-back, source proof, and promotion path. Restore and
  issuance remain refused for both recovery outbox states. Both states round-trip through the
  bounded retained codec, and forged, metadata-changing, non-conflict, absent, corrupt, or
  unobservable variants fail closed. The focused Authority fold/endpoint suite passes **27/27** at
  `/tmp/prodbox-sprint-6.5-tls-recovery-v2-collision-authority-codec-focused-final.log`,
  `sha256:fd6b04d27a4bcd846724c16746b1fae72d4f5b5239b0f83f372698c3bfd3a01c`; the full TLS
  workflow suite passes **32/32** at
  `/tmp/prodbox-sprint-6.5-tls-recovery-v2-collision-endpoint-focused.log`,
  `sha256:c03c96ca1454602510bff1218d4a433bad745882e31655e9f2f4ebc0465d87df`. Canonical unit
  validation passes **4,884 + 27 + 35 + 36** with exit 0 at
  `/tmp/prodbox-sprint-6.5-tls-recovery-v2-collision-unit-final-after-lint.log`,
  `sha256:6d8d41a7f5d00aa07a2184c7357ddcadeb841124f2e7c894806e7de348b5fef7`.
  Documentation-inclusive `prodbox dev check` passes with exit 0 at
  `/tmp/prodbox-sprint-6.5-tls-recovery-v2-collision-dev-check-final.log`,
  `sha256:809694359946a54323e25c1ca8c8418c709b6f99c40a2965008bc47e410a82bb`; the synchronized
  executable is `sha256:a51a7623f72d4b1327ef29f105d05f2da13eb524b0e7d6f23736143a65feef4e`.
  Exact live `pre-1` remains next. No candidate qualification artifact, activation witness, or exact
  cleanup proof exists, and the legacy public writer remains sole.
- The exact collision-recovery `pre-1` runs from **2026-09-08 06:10:54–06:52:22 EDT** on local
  runtime image `sha256:4dc0e173cc2aa002103b90444c1b8c49a87c58ab68c2cc732fd6149208cd2e67`,
  tag `prodbox-3349a232b3454fb3be77b2f68919904f`, and Registry manifest
  `sha256:93ecb4fb473254c89ed7b4a7b0fd6391ed0df18094c1d8fdd09f0f2caf5fc91e`.
  It crosses complete home-platform reconciliation and chart deletion. The exact immutable
  version-2 collision is observed, but applying those occupied canonical bytes fails at the
  retained-home rewrap with the closed cause
  `home-agent/home-rewrap-ciphertext-authentication-failed`; restore then correctly selects
  `pending-without-current`, and retain-on-ready repeats the same authentication failure. Stable
  counterexample
  `TLS-LEGACY-RECOVERY-V2-COLLISION-CIPHERTEXT-AUTHENTICATION-FAILED-2026-09-08` owns this exact
  boundary. The licensed repair is one bounded fixed-version-3 successor only from the durable
  legacy-recovery version-2 pending state after exact version-2 conflict, exact-key observation,
  and that closed authentication failure. It must retain the displaced version-2 pending identity
  and both version-2 digests in Authority state, create fresh version-3 selected-Agent
  ciphertext because the certificate AEAD binds its retention version, stage the complete
  version-3 outbox by CAS before its immutable PUT, and retain restore/issuance refusal until
  ordinary exact read-back, source re-observation, and promotion. It may not overwrite/delete
  either older object, infer the occupied object's certificate/source metadata, select latest, or
  advance beyond version 3. The wrapper restores the public edge to `ready-for-external-proof`;
  VS Code delete/reconcile remains the repeated best-effort failure, exact cleanup is unproved,
  and operational credentials remain preserved. The transcript is
  `/tmp/prodbox-sprint-6.5-tls-recovery-v2-collision-live-pre-1.log` at
  `sha256:84d3f115b25039a195cd4dfd27e6961b3900f4144f748fa5886b44adde490bca`.
  No candidate qualification artifact or activation witness exists, and the legacy public writer
  remains sole.
- That counterexample is now closed on its code-owned boundary. The existing recovery-stage
  request schema remains unchanged: candidate version 2 means the already-proved occupied-byte
  adoption, while candidate version 3 selects one appended
  `TlsRetentionLegacyRecoverySuccessorPendingState`. The latter is constructible only from the
  exact version-2 recovery-pending state and collision evidence. It durably retains legacy-v1
  evidence, both version-2 digests, the displaced approval/candidate identity, and one complete
  fresh version-3 outbox; approval, certificate, and source must remain identical, all three
  envelope digests must be distinct, and restore/issuance remain refused. The workflow stages that
  state before version-3 PUT and then uses only ordinary exact read-back, source verification, and
  promotion. Version-3 mismatch and every version-4 attempt refuse. Because this adds two requests
  to the worst successful Target-Agent attempt, its derived retained replay envelope is now
  `2 * 34 = 68` entries with a 138 MiB bound. Replay codec v11 monotonically admits canonical v10
  capacity 64 with identical response/skew limits and preserves every entry; shrink, drift,
  malformed/noncanonical state, and clearing still refuse. Focused Authority fold/endpoint tests
  pass **30/30** at `/tmp/prodbox-sprint-6.5-tls-v3-successor-authority-focused.log`,
  `sha256:e4489b984b3190ccaae0b83f8b7b9e621bc36bc7327a5f694bfda9c1ac8ddb19`; the TLS workflow
  suite passes **33/33** at `/tmp/prodbox-sprint-6.5-tls-v3-successor-workflow-focused.log`,
  `sha256:9f8ae7da8e87623a9e4cd7e3a83a78993d2b90b3d17ac33f56295f28245f2413`; authenticated
  transport/replay passes **36/36** at
  `/tmp/prodbox-sprint-6.5-tls-v3-successor-transport-focused.log`,
  `sha256:21a64ce203f9dd9439dce14de1e2345cba0ee856dcf7697ec902b2146f3042cd`; and the runtime
  capacity focus passes **1/1** at
  `/tmp/prodbox-sprint-6.5-tls-v3-successor-runtime-capacity-focused.log`,
  `sha256:e9cbcd1b62180fe07f8d9235bd51ea8ce6d121a6b0f244f248895292e4c59412`.
  Complete unit validation passes primary **4888/4888** plus auxiliaries **27/27**, **35/35**, and
  **36/36** at `/tmp/prodbox-sprint-6.5-tls-v3-successor-unit.log`,
  `sha256:b5adaff3182eed1fc124c0dccbd047a71e4a6dd5e637deffabeaadde6eaab7f4`. Canonical
  documentation-inclusive `prodbox dev check` passes with the pinned formatter, HLint `No hints`,
  policy and generated-document checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-tls-v3-successor-dev-check.log`,
  `sha256:2a23ef64776f25a394fa324b0736467a8b8d2278e672137bbfa81038211ae698`. Diff validation passes,
  and the gate-built installed executable is
  `sha256:bd708bebf5542d7c618f3e9de5fee9490b22c2bdbb888fb8929fd351959928b7`.
  A ledger-inclusive canonical rerun also passes at
  `/tmp/prodbox-sprint-6.5-tls-v3-successor-ledger-inclusive-dev-check.log`,
  `sha256:f1ca6775524a18bc1a6584b1d7d95b62ad9e2a3813696d64ddd7b75b7953734c`.
  The unchanged exact next action is live home `pre-1` qualification with that executable. No
  qualification state changes, and the legacy writer remains sole.
- The exact live home `pre-1` retry starts at **2026-09-08T10:40:33-04:00** and ends at
  **2026-09-08T11:22:38-04:00** with status **1** at
  `/tmp/prodbox-sprint-6.5-tls-v3-successor-live-pre-1.log`,
  `sha256:a829ec4b59dfd8193bded88029639b3a650fbc73a1270bab9f08ff04da353dad`. It builds local
  image `sha256:752fef87d320272a973a2f68283bc1af81bbc93881dd4a3d4b7cb434d31ff9c5` in
  **1,129.3 s**, publishes registry manifest
  `sha256:5a16417bf2d5c14c10b2d7da90571f2bc4811b4a1d8e35d1e3314df6d431ebe3`, imports OCI
  manifest `sha256:8062f2040c67d30241407c54b566db38e29e18c39c83b9cbe801b8d2f504f468`, admits the
  retained Authority generation through the version-11 replay-capacity migration, and crosses full
  home-platform reconciliation. The TLS-retention delete path nevertheless returns
  `TlsRetentionWorkflowAuthorityAdapterUnavailable`; Authority logs retain exact version-2
  repository conflict `put/conflict/confirmation/bytes-mismatch`, restore correctly refuses the
  remaining `pending-without-current` state, and retain-on-ready repeats adapter-unavailable.
  Stable counterexample `TLS-LEGACY-RECOVERY-V3-IMMUTABLE-COLLISION-2026-09-08` owns the exact
  conflict between the durably staged fixed-version-3 successor and the pre-Authority legacy object
  lane. The restore graph deletes
  websocket, API, and gateway, then reconciles gateway, API, websocket, and the public edge; VSCode
  delete and reconcile both fail. Final edge classification is `ready-for-external-proof`, exact
  terminal cleanup is unproved, and operational credentials are preserved for recovery. A scoped
  read-only fixed-key probe at `/tmp/prodbox-sprint-6.5-tls-legacy-lane-fixed-probe.log`,
  `sha256:d79dcbe6ae842747e7fc017d717f14df07b9c2da2c26b7da99bd1d4a0aadd819`, proves exact legacy
  `versions/1.envelope` through `versions/12.envelope` all present with distinct ETags, S3 version
  IDs, and creation times from September 3–5. It performs no list/latest read and no mutation. An
  initial AWS-CLI metadata probe exceeded the Adapter Pod's **80 MiB** limit once; Kubernetes
  reports the exact `OOMKilled`/137 restart and the Pod is again Ready before the bounded curl probe
  ends. The licensed correction is therefore not another guessed integer and not object cleanup:
  retain exact legacy compatibility observations at `versions/<n>.envelope`, but place every
  Authority-owned immutable store/read-back/restore at the disjoint fixed protocol lane
  `authority-v1/versions/<n>.envelope`. The already-durable version-3 successor outbox then resumes
  the same bytes into the new lane; neither legacy objects nor Authority state are rewritten, and
  there is still no version 4, recursive recovery, list, latest, overwrite, or delete transition.
  The bounded lane split is now implemented without changing the durable Authority state or the
  legacy observe payload's canonical single-field wire encoding. The store, confirmation, current
  restore, and successor-collision observer derive only `authority-v1/versions/<n>.envelope`; the
  initial empty-state compatibility observer alone derives `versions/<n>.envelope`. A distinct
  lane-tagged payload selects the Authority observer on the existing authenticated route, and
  neither payload admits a caller-selected key. Stable counterexample regression
  `TLS-LEGACY-RECOVERY-V3-IMMUTABLE-COLLISION-2026-09-08` passes **1/1** at
  `/tmp/prodbox-sprint-6.5-tls-authority-lane-focused.log`,
  `sha256:ee1e4d85fb7d4121d9727cba320862c886d32bf29b8073c0f9ba43f3313c8d17`; documentation and
  the component inventory now name both lanes. Full unit validation passes **4,889 + 27 + 35 +
  36** at `/tmp/prodbox-sprint-6.5-tls-authority-lane-unit.log`,
  `sha256:b701f1a4a8c3b69e5b8398e8b1a4b7ef9830bc0742728ea16abea102eba90bc0`. Canonical
  documentation-inclusive `prodbox dev check` passes with the pinned formatter, HLint `No hints`,
  policy/generated-document checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-tls-authority-lane-dev-check.log`,
  `sha256:7d4e8a561d9a8b8f1abc457b4dfc7a2aa61f359e39bf49fc5fb9b5d5fab47a62`; diff validation
  passes and the synchronized executable is
  `sha256:6cbd2e77bc590823712c16d4c48ab481fb47244acb4e28ab0e50031a3b305bd2`. The
  ledger-inclusive canonical rerun also passes at
  `/tmp/prodbox-sprint-6.5-tls-authority-lane-ledger-inclusive-dev-check.log`,
  `sha256:f1ca6775524a18bc1a6584b1d7d95b62ad9e2a3813696d64ddd7b75b7953734c`. The exact next
  action is another live home `pre-1` with that executable. No candidate cycle qualifies, and the
  legacy writer remains sole.
- The exact lane-split live `pre-1` runs from **2026-09-08T12:33:59-04:00** through
  **2026-09-08T13:27:42-04:00** and exits **1** at
  `/tmp/prodbox-sprint-6.5-tls-authority-lane-live-pre-1.log`,
  `sha256:87ef44787b952420f68a14edd157175cc460b87b181ab9fe3eefd83b115e0e84`. It builds local
  image `sha256:5732dc206a097971aec358868358592c9f08fedb74b8ced05029b440872877f3` in
  **1,125.6 s**, publishes Registry manifest
  `sha256:7e5f964adb433e0b30ff918c6e7aac5af75f03c6cd76eed3c02b2fa63a1b8b28`, and imports OCI
  manifest `sha256:d4682b9477171504f1167ff0b307f866f9675403c1e4438c0ffa5ecac2a0c10e` in **93.4 s**;
  retention removes only the immediately superseded Registry manifest `5a16417b…` and local image
  `752fef87…`. This live-closes
  `TLS-LEGACY-RECOVERY-V3-IMMUTABLE-COLLISION-2026-09-08`: TLS retention reports exact Authority
  and Adapter custody, websocket/API/VS Code/Gateway delete, all preserved-volume restores, and the
  public edge complete. The final edge is `ready-for-external-proof`; a later non-fatal
  retain-on-ready attempt reports `TlsRetentionWorkflowAuthoritySourceReadBackMismatch` but does
  not stop the restored graph.
- The disqualifying terminal is the already-registered live-open
  `AUTHORITY-PROVIDER-DISPATCH-RESPONSE-INVALID-2026-09-06`. After an EKS-subzone Provider receipt,
  the registered stack lifecycle generation commits as `AwsStackCreationCommitCreated`, but its
  admitted create returns
  `AuthorityProviderResponseInvalid ControlPlaneRequestInvalid` with exact value-free observation
  `status=client-error,size=within-bound,shape=other`; a stack may exist under that cycle. Exact
  terminal cleanup is not proved and operational credentials remain preserved. Freeze that
  route's Authority/Provider production logs and exact source response projection to identify the
  unrecognized bounded response producer before changing response acceptance, encoding,
  authentication, dispatch, settlement, or recovery. No candidate cycle qualifies, and the legacy
  writer remains sole.
- Scoped read-only evidence closes the response-shape diagnosis without exposing credentials,
  request bodies, or Provider resource coordinates. Lifecycle Authority and Provider Worker logs
  are `/tmp/prodbox-sprint-6.5-provider-response-authority-logs.log`,
  `sha256:28a86daaec15ef3e480254ae099a08f954de4faa111e8537399bbd5f2eba3888`, and
  `/tmp/prodbox-sprint-6.5-provider-response-worker-logs.log`,
  `sha256:d1b1858968e7ae5c993be062eded5138804e71869d1770985bcb34a4ef15de14`. The final Provider
  request completes ingress, admission, trust/time, narrow-session, and credential-binding, enters
  capability execution at **17:22:43.089084367Z**, emits no
  capability/projection/encoding completion, and records only socket completion at
  **17:27:44.137002648Z**. Source projection proves the outer Lifecycle Authority server
  independently authors HTTP 408 `request-deadline-exceeded` at its generic 300-second
  accepted-connection bound, racing the nested Provider Worker's unchanged 300-second server
  envelope before Authority can encode `ProviderDispatchResponse`.
- The bounded correction leaves the Provider child, Provider Worker server, authentication,
  replay, operation identity, and every sibling role at their existing limits. Only the Lifecycle
  Authority accepted-connection envelope consumes the already-typed 330-second Provider response
  bound, so an inner terminal response has its documented 30-second projection margin. Stable
  diagnostic and budget regressions pass **2/2** at
  `/tmp/prodbox-sprint-6.5-authority-provider-server-budget-formatted-focused.log`,
  `sha256:db59aae772c64871513565194cec7da98db6c19e4a96f9cb0a7d3280bb7090d6`; lifecycle and
  resource-scaling doctrine plus the component inventory now name the nested server bound. Run
  full local gates before the unchanged live `pre-1`. The Provider response counterexample remains
  live-open until that replay, no candidate cycle qualifies, and the legacy writer remains sole.
- Full unit validation for the nested Provider server budget passes **4,890 + 27 + 35 + 36** at
  `/tmp/prodbox-sprint-6.5-authority-provider-server-budget-unit.log`,
  `sha256:fc55f3c5522a1ba4b40e3c3fd326c87548c7d63489a1cbe741a3ab2b257889bc`. Run the
  canonical all-target quality gate before rebuilding the executable and replaying live `pre-1`;
  the counterexample remains live-open, no candidate cycle qualifies, and the legacy writer
  remains sole.
- Canonical `prodbox dev check` passes with the pinned formatter, HLint `No hints`, policy and
  generated-document checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-authority-provider-server-budget-dev-check.log`,
  `sha256:5f78f176c5a83a2d11cf8c136a7b22d79d831fc3d4a9d178f581bf7f24beffab`; diff validation
  passes and the synchronized executable is
  `sha256:440d73ac61a7a1cc74a98cb959bd714f736d20c021c17a6de785e342b9e67aa7`. Run the
  ledger-inclusive canonical gate before replaying live `pre-1`; no candidate cycle qualifies and
  the legacy writer remains sole.
- The ledger-inclusive canonical rerun also passes at
  `/tmp/prodbox-sprint-6.5-authority-provider-server-budget-ledger-inclusive-dev-check.log`,
  `sha256:823f917f14d3e63e56dd225cc12896e31bec14eecc0dafcec280b16dfc66e7fc`; the
  synchronized executable remains exact at
  `sha256:440d73ac61a7a1cc74a98cb959bd714f736d20c021c17a6de785e342b9e67aa7`. The exact next
  action is the unchanged live home `pre-1` recovery replay. No candidate cycle qualifies, and the
  legacy writer remains sole.
- Final documentation lint and diff validation pass; the empty lint transcript is
  `/tmp/prodbox-sprint-6.5-authority-provider-server-budget-final-docs-lint.log`,
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. Proceed with the
  live home `pre-1` recovery replay.
- The nested-budget live `pre-1` runs from **2026-09-08T14:16:10-04:00** through
  **2026-09-08T14:58:59-04:00** and exits **1** at
  `/tmp/prodbox-sprint-6.5-authority-provider-server-budget-live-pre-1.log`,
  `sha256:56028c7689291b321efa7aa27c48a6a086a12590aa2b6ed55528748835985fea`. It builds local
  image `sha256:6692d7fb468bd2aa1449d2a49ce40421a8e6bea1d06b733b56b0e360e6201317` in
  **1,122.9 s**, publishes Registry manifest
  `sha256:c5933c1a95ef8c0be1b1a51ce47515e04100fafa991da901587c73947db5452c`, and imports OCI
  manifest `sha256:3f1333c05e9ad3e0167333c2ada281740752c76662eaac93eca123aa1bafa83b` in **88.0 s**;
  retention removes only the immediately superseded manifest `7e5f964a…` and image `5732dc20…`.
  The run does not re-reach the Provider operation. Its total restore deletes and restores
  WebSocket/Redis, API, and Gateway/Pulsar and proves the public edge `ready-for-external-proof`,
  but the certificate-owning VS Code delete refuses at
  `TlsRetentionWorkflowAuthoritySourceReadBackMismatch` and its restore refuses at
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`. Stable counterexample
  `TLS-AUTHORITY-RETAIN-READBACK-MISMATCH-SELECTED-AGENT-UNAVAILABLE-2026-09-08` owns that exact
  Authority retain→restore sequence. Freeze scoped Lifecycle Authority, TLS Retention Adapter, and
  Target Agent evidence before changing the workflow, custody, selection, or retry semantics.
  Exact terminal cleanup is not proved, operational credentials remain preserved, no candidate
  cycle qualifies, and the legacy writer remains sole; the Provider response counterexample also
  remains live-open because this run did not reach it.
- Time-scoped read-only logs prove every participating Pod Ready with zero restarts and close the
  counterexample to selection logic rather than workload loss. The timestamped Lifecycle Authority
  and Target Agent transcripts are
  `/tmp/prodbox-sprint-6.5-tls-authority-sequence-authority-timestamped.log`,
  `sha256:0765a52ed9f11f74735812eed8b55fe14dae1c99e00320e2a229c7d42531a0a1`, and
  `/tmp/prodbox-sprint-6.5-tls-authority-sequence-agent-timestamped.log`,
  `sha256:98e4d924816a23a35bd1b159d03c32e68be600c632ad8ca35d7f257458ed3c3d`; the Adapter log
  is exactly empty at `/tmp/prodbox-sprint-6.5-tls-authority-sequence-adapter-logs.log`,
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. At 14:55:21 the
  Authority reports `legacy-adoption-not-idempotent`; at 14:57:53 the independent VS Code restore
  reaches the selected Agent and correctly refuses `secret-apply-failed/existing-content-mismatch`;
  at 14:58:58 the later retain reports one-shot preclean classification failure.
- Source makes the first failure exact. After any promoted Authority current version,
  `retainPublicEdgeTlsWorkflow` still observes the old legacy `versions/<next>.envelope` lane before
  creating a fresh next version. This installation retains legacy versions 1–12 while Authority
  current is version 3, so legacy version 4 is incorrectly treated as an adoption candidate and
  combined with the newly observed live source. The source read-back mismatch correctly refuses
  that non-idempotent composition; delete therefore leaves the live namespace present, and the
  total graph's independent restore correctly refuses replacing its different live certificate
  with Authority version 3. Restrict legacy observation/adoption to genesis `TlsRetentionEmpty`;
  once an Authority current exists, create the fresh successor directly in the disjoint
  `authority-v1` lane. Preserve the exact empty-state migration, immutable collision recovery,
  source verification, one-shot cleanup, and all refusal semantics. The later preclean failure
  remains secondary evidence to re-evaluate after this causal correction.
- The genesis-only legacy observation correction is code-local complete. A promoted Authority
  current now enters fresh successor creation directly, while `TlsRetentionEmpty` retains the exact
  legacy migration/recovery branch and pending state still resumes before either. The stable
  counterexample regression extends the existing stage-before-PUT/interruption test through a
  second post-promotion retention and fails if that successor calls the legacy observer; it passes
  **1/1** after formatting at
  `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-focused.log`,
  `sha256:92fcbb7d0fa52bd107fec6b7ba3eadd7cff92b126c2e2c7404bbc3ed2053cb1b`. The pinned
  formatter passes with HLint `No hints` at
  `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-format.log`,
  `sha256:b62764783a0004e9ca9cf455f2de37d9ba8b9c3f37056014cc3c5d74bb053b40`; diff validation
  passes, and lifecycle doctrine plus the certificate-material inventory now state the
  genesis-only rule. Run full local gates before another live `pre-1`. The live counterexample
  remains open until that replay, no candidate cycle qualifies, and the legacy writer remains
  sole.
- Full unit validation for the genesis-only legacy observation correction passes
  **4,890 + 27 + 35 + 36** at
  `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-unit.log`,
  `sha256:38d14fb5bed44d7e29b28888b82a55f961c7e65728677f65cc517994ff189769`. Run the
  canonical all-target quality gate before rebuilding the executable and replaying live `pre-1`;
  the counterexample remains open, no candidate cycle qualifies, and the legacy writer remains
  sole.
- The canonical all-target quality gate for that correction exits **0** with HLint `No hints` at
  `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-dev-check.log`,
  `sha256:693043863ee70476cb30f9822513844e67e9971e829db245bf1521dc429ca1d4`. The rebuilt
  executable is `sha256:a8a3646bd7f0f09f5db45d9b2bab34f0d93ce0ee939df73ee0034416b4181143`.
  Record the evidence in both ledgers and validate that ledger-inclusive tree before replaying live
  `pre-1`; the counterexample remains open, no candidate cycle qualifies, and the legacy writer
  remains sole.
- The ledger-inclusive canonical quality gate also exits **0** with HLint `No hints` at
  `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-ledger-inclusive-dev-check.log`,
  `sha256:f1ca6775524a18bc1a6584b1d7d95b62ad9e2a3813696d64ddd7b75b7953734c`. Run the final
  documentation-only and diff checks, then replay live `pre-1` under the exact rebuilt executable;
  the counterexample remains open, no candidate cycle qualifies, and the legacy writer remains
  sole.
- The final documentation check and documentation lint both exit **0** with empty output at
  `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-final-docs-check.log` and
  `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-final-docs-lint.log`, each
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`; `git diff
  --check` also exits **0**. The local correction is fully validated. Replay live `pre-1`; the
  counterexample remains open until live evidence closes it, no candidate cycle qualifies, and the
  legacy writer remains sole.
- The corrected live `pre-1` from **2026-09-08 15:48:35–16:37:44 EDT** is not a candidate. Its
  transcript is `/tmp/prodbox-sprint-6.5-tls-authority-current-lane-live-pre-1.log`,
  `sha256:a7937c29f1df4886a38ba5f320fd755a5cd4c28ba162fdffa6669d9e36849660`. It builds
  local image `sha256:ee7c4605d462a8462fa2b9c90348b9d1d8f6b45cca4d471b0165c5778ae9312e`
  in **1,112.1 s**, publishes Registry manifest
  `sha256:8a1e8eec8c401705fd1c25cea883b43bda2d796c26ce8e1cc17d2a2689b13e3b`, and imports
  OCI manifest `sha256:ac1d22e496c63fb7e2181bd6968c407b77d5ebe9ca9cc0491e71fce10f135e52`
  in **93.8 s**; retention removes only the immediately superseded manifest/image. The exact VS Code
  delete now reports `retained through the Authority and TLS Retention Adapter`, and the whole
  gateway/VS Code/API/WebSocket graph restores with its exact retained bindings and a
  `ready-for-external-proof` public edge. This live-closes the blocking retain read-back and restore
  arms of `TLS-AUTHORITY-RETAIN-READBACK-MISMATCH-SELECTED-AGENT-UNAVAILABLE-2026-09-08`.
  The later non-fatal retain-on-ready arm remains open: the Target Agent reports
  `coordinator/session-prepare-failed/preclean/classification-failed`, projected by the Authority as
  `selected-agent/http-status/target/retain/one-shot-operation-unavailable`.
- The widened nested server budget is also live-confirmed: Provider capability execution runs from
  16:36:17 to 16:37:43 and the complete structured 503 reaches the host rather than being replaced
  by the outer Authority timeout. Stable counterexample
  `AWS-EKS-TEST-RECONCILE-IAM-NAME-COLLISION-2026-09-08` owns its disqualifying terminal. The
  registered generation is `AwsStackCreationCommitCreated`; Pulumi creates a VPC, then AWS refuses
  the deterministic cluster role, node role, and Load Balancer Controller policy with exact 409
  `EntityAlreadyExists`, so a stack may exist and cleanup is not proved. Operational credentials are
  correctly preserved. All four scoped role Pods are Ready, zero-restart, and on the exact local
  image. Scoped logs are Lifecycle Authority
  `/tmp/prodbox-sprint-6.5-current-lane-live-pre-1-authority.log`
  (`sha256:263f6adc32e56d9174f1c15c336ce486913313fc40520bb0a6e5e1b30ed44cb8`), empty TLS
  Retention Adapter log (`sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`),
  Target Agent `/tmp/prodbox-sprint-6.5-current-lane-live-pre-1-target-agent.log`
  (`sha256:ed8287da66b204907f88da0225d48509381f811ed62a5cf5cebab99a132d2067`), and Provider
  Worker `/tmp/prodbox-sprint-6.5-current-lane-live-pre-1-provider-worker.log`
  (`sha256:2b9ad188ab962582570f98d910aa2879401685bf329038173b1fcebe3858950b`). Run the
  registered `prodbox aws stack test destroy --yes` recovery and require exact terminal absence
  before another `pre-1`; no candidate cycle qualifies and the legacy writer remains sole.
- The first registered recovery probe, `prodbox aws stack test destroy --yes`, exits **0** at
  16:41:37 EDT and reports only `AWS test Provider destroy receipt: registered stack is absent`.
  Transcript `/tmp/prodbox-sprint-6.5-aws-eks-test-iam-collision-stack-test-destroy.log` is
  `sha256:ba4de51772570a3f18fb314a1c500f75668a1b4df74c46f103a981b0ee4a1b7c`. That exact
  stack-checkpoint absence does not prove the independently registered deterministic IAM family
  absent; treating it as cleanup would reproduce the collision. Run the full registered cascade
  desired-absence graph, whose independent IAM-family adapter is a predecessor of EKS stack
  absence, and require its exact terminal evidence. The counterexample remains open, no candidate
  cycle qualifies, and the legacy writer remains sole.
- The registered cascade recovery from **2026-09-08 16:42:49–16:43:45 EDT** exits **1**, correctly
  withholds a completion receipt, and selects stable counterexample
  `CASCADE-AWS-EKS-PROVIDER-CHECKPOINT-STACK-DESCRIPTOR-MISSING-2026-09-08`. Transcript
  `/tmp/prodbox-sprint-6.5-aws-eks-test-iam-collision-cascade-recovery.log` is
  `sha256:25ddb0d68f902f306d3cec56f49426e0ab8ae7efc294f111de287f4f88293d21`. The retained
  checkpoint observer classifies `aws-eks` and `aws-eks-subzone` present and `aws-test` absent,
  while the EKS drain cannot materialize a kubeconfig because the `aws-eks` checkpoint is
  unavailable. The Provider destroy then fails closed while storing the encrypted checkpoint:
  `the managed resource registry declares no stack descriptor for aws-eks; registered stack is
  present`. The EBS reaper proves its own family clean; local uninstall completes; the independent
  tag sweep still observes the EKS cluster plus its VPC/subnet/gateway/route-table/security-group
  family. Exact AWS cleanup is therefore unresolved and the retained root has no retirement
  license. Restore mandatory local RKE2 through `prodbox cluster reconcile`, freeze the
  stack-descriptor lookup and checkpoint-materialization call paths, and correct the registered
  identity mismatch before rerunning the cascade recovery. No candidate cycle qualifies and the
  legacy writer remains sole.
- Mandatory local recovery succeeds from **2026-09-08 16:44:46–16:59:16 EDT** through `prodbox
  cluster reconcile`. Transcript
  `/tmp/prodbox-sprint-6.5-stack-descriptor-counterexample-cluster-reconcile.log` is
  `sha256:3992734d4d0ee51e2a70e300aa9c8655eb93bf350dbcba63f4e730688eba7258`. RKE2,
  Registry, Vault, Lifecycle Authority, Authority Backup, Provider Worker, gateway, and TLS
  Retention are restored; Vault reuses the exact retained root/session/storage identity and the
  runtime reuses the exact local/Registry/OCI image identities from the rejected run. Source
  diagnosis opens Sprint `4.91`: the Authority checkpoint registration deliberately names the
  canonical registry key `aws-eks`, but `checkpointCapabilityForStackName` compares that input to
  `AwsPulumiStackCoordinate`'s Pulumi stack ID `aws-eks-test`. Match the exact registered
  resource-key text instead, pin all registered stack capabilities plus the negative provider-ID
  alias, and leave checkpoint bytes, lifecycle decisions, custody dispositions, and every other
  stack unchanged. Sprint `6.5` is blocked on that earlier-phase correction; no candidate cycle
  qualifies and the legacy writer remains sole.
- Sprint `4.91` is now Done and Sprint `6.5` deploys its exact correction through `prodbox cluster
  reconcile` from **2026-09-08 17:43:06–18:11:46 EDT**, exit **0**. The clean union-runtime build
  completes in **1,111.7 s** as local image
  `sha256:971ea616540108816089f53f091c21b401b9794a01690b772ada2bca4104697c`, publishes
  Registry manifest `sha256:bc6f777e1aa021184b8fa7b68a22b18018a8d13f623a41c62c2831546202776f`, and
  imports OCI manifest
  `sha256:7855a36444cb8a227510f4becdb84f91e4fef5a0de22a6d5913c64b7dd7171e2` in **88.9 s**.
  Vault reuses the exact retained root session, storage generation, and baseline digest;
  Lifecycle Authority, Authority Backup, Target Agent, Provider Worker, Gateway, and TLS Retention
  all cross the current reconcile graph. Transcript
  `/tmp/prodbox-sprint-6.5-checkpoint-custody-fix-deploy-cluster-reconcile.log` is
  `sha256:7537e4da673647ecdaff36ab56cfbcccc5ae32718876e2653cd4c49cc9f50cbe`. The registered
  cascade recovery is next; require its exact terminal evidence before claiming the stranded AWS
  graph absent. No candidate cycle qualifies and the legacy writer remains sole.
- That corrected cascade recovery runs from **2026-09-08 18:13:35–18:15:56 EDT** and exits **1**,
  correctly withholding a completion receipt. It live-closes the Sprint-`4.91` lookup refusal:
  both current checkpoint registrations reach fresh Provider operations 50/51, both destroys
  complete, their references retire, and post-destroy observations return `registered stack is
  absent`. The immutable retired EKS checkpoint has plaintext digest `b2f…` and owns
  `vpc-08bd233bb0d435a8f`; the terminal 19-row tag audit instead owns the older EKS cluster and
  `vpc-0cc44cd337d7dc6c7` family. The Provider result therefore describes the exact destroyed
  registered generation while the audit correctly finds an older generation that escaped current
  checkpoint custody. EKS kubeconfig hydration was unavailable because the registered partial
  checkpoint contained only the stack, provider, and VPC, with no output snapshot from which to
  construct access. The EBS reaper alone is clean; local RKE2 is uninstalled and the retained root
  remains preserved without retirement authority. Transcript
  `/tmp/prodbox-sprint-6.5-checkpoint-custody-fix-cascade-recovery.log` is
  `sha256:88f4a5eb4c54bd7486eb3feb4d2acdaabe22d50b0972fbaf50ae3abab04ea268`. The diagnostic
  hypothesis `CASCADE-AWS-EKS-CHECKPOINT-AWS-TRUTH-DIVERGENCE-2026-09-08` is falsified and closed.
  Stable counterexample `CASCADE-AWS-EKS-OLDER-GENERATION-CHECKPOINTLESS-ORPHAN-2026-09-08` owns
  the actual boundary and selects the qualification candidate's bounded native
  recovery/adoption path; no Provider checkpoint fix or earlier-phase reopening is licensed.
- The mandatory retained local control plane is restored by `prodbox cluster reconcile`; the run
  exits **0** with Lifecycle Authority, Authority Backup, Provider Worker, MinIO, and Vault Ready.
  Transcript `/tmp/prodbox-sprint-6.5-checkpoint-aws-truth-divergence-cluster-reconcile.log` is
  `sha256:a02eda6851b7e4214f59209ee1ed11baedc64c4d0f1ea377445ae8e3a4235e99`. Run the unchanged
  qualification-only `pre-1` candidate next. No candidate cycle qualifies and the legacy writer
  remains sole.
- That unchanged `pre-1` runs from **2026-09-08 19:13:47–19:39:29 EDT** and stops before candidate
  dispatch. The retained-home, credential, Gateway, TLS, and application restore surfaces converge,
  then the ordinary AWS bootstrap first reconciles the subzone and attempts to create a fresh EKS
  generation. Pulumi creates a new exact VPC checkpoint, but the checkpointless older cluster role,
  node role, and Load Balancer Controller policy refuse creation with exact AWS 409
  `EntityAlreadyExists`; the registered generation remains `AwsStackCreationCommitCreated`, so a
  stack may exist and operational credentials remain preserved. Transcript
  `/tmp/prodbox-sprint-6.5-checkpointless-older-generation-live-pre-1.log` is
  `sha256:278cff14ae2fd6476dba40a260ff4d3d11c588ab1bd1d505dc4219ccc56a08a4`. Stable
  counterexample `CASCADE-QUALIFICATION-BOOTSTRAP-PRECEDES-RESIDUE-RECOVERY-2026-09-08` owns the
  ordering defect: the qualification-only surface needs one explicit recovery mode that skips fresh
  AWS substrate provisioning and dispatches the same typed candidate against already
  committed/residual state. It must remain non-public, preserve the ordinary `pre-1`/`pre-2`
  provisioning path, and use a distinct stable recovery cycle identity. No candidate cycle
  qualifies and the legacy writer remains sole.
- That ordering correction is code-locally complete. `CascadeQualificationBootstrapMode` converts
  the test-cycle environment boundary into either ordinary fresh provisioning or existing-state
  recovery; only the exact qualification suite and a nonempty `recovery-<identity>` label select
  the latter. Recovery mode emits its choice and skips only the AWS stack/chart bootstrap, leaving
  the retained-home, credential, runbook, prerequisite, private candidate, and evidence paths
  unchanged. Ordinary `pre-1`/`pre-2` and every other suite retain fresh provisioning. Both exact
  selector regressions pass **1/1**, warning-clean affected-target compilation passes, and the
  complete primary suite passes **4,891/4,891 in 88.32 s**. Transcripts are
  `/tmp/prodbox-sprint-6.5-recovery-bootstrap-mode-{other-suite-focused,focused,primary-unit}.log`
  at respective SHA-256 digests `97b322b4…`, `d42509f5…`, and `65baca70…`. Run the
  documentation-inclusive canonical gate, synchronize its binary, then invoke stable cycle
  `recovery-older-generation`; no preactivation qualification row changes until live evidence
  exists.
- The documentation-inclusive canonical gate now exits **0** with pinned formatting, HLint `No
  hints`, generated-artifact/documentation checks, and warning-clean all-target compilation. Its
  transcript is `/tmp/prodbox-sprint-6.5-recovery-bootstrap-mode-dev-check.log` at
  `sha256:ac51ba9b04129b430386cd865e070aa367e6dc7f651106d3df150c8d51a820c9`; final
  documentation check, documentation lint, and `git diff --check` also pass. The synchronized
  executable is exact at
  `sha256:a2ba8febfca0d2153e1e25dcf43bf52d67f12b2531d6c72cdaf410690b285c07`. Run
  `recovery-older-generation` through the qualification-only command; the legacy public writer
  remains sole.
- The recovery-labelled live run from **2026-09-08 20:11:37–20:59:24 EDT** validates that ordering
  correction: it emits the explicit recovery-mode marker, skips fresh AWS stack/chart
  provisioning, and reaches Phase 2 candidate dispatch after the complete retained-home restore.
  It then exits **1** before the candidate body because the blanket AWS validation wrapper calls
  `withEksKubeconfig`, which requires the now-retired current `aws-eks` output checkpoint.
  Transcript
  `/tmp/prodbox-sprint-6.5-recovery-bootstrap-mode-live-recovery-older-generation.log` is
  `sha256:bcf4716c6268f90156a88641527bddee82b58e865e008b46737d85be8cf9d73f`. Stable
  counterexample `CASCADE-QUALIFICATION-EAGER-EKS-KUBECONFIG-BEFORE-CANDIDATE-2026-09-08` owns
  the execution-context defect: the qualification candidate observes its source image inventory
  on the retained local control plane and its cloud runtime obtains operation-bound ephemeral EKS
  client projections from the Provider. Remove only that redundant outer wrapper for this
  validation; ordinary AWS-target validations retain it. No candidate cycle qualifies and the
  legacy writer remains sole.
- That execution-context correction is code-locally complete.
  `NativeValidationKubeconfigMode` keeps the selected-substrate wrapper for every ordinary
  validation and selects self-owned scopes only for `ValidationCascadeQualification`; the
  candidate's existing local inventory observation and Provider projection boundaries remain
  unchanged. The exact focused regression passes **1/1** and the complete primary suite passes
  **4,891/4,891 in 87.98 s**. Transcripts
  `/tmp/prodbox-sprint-6.5-cascade-owned-kubeconfig-{focused,primary-unit}.log` have respective
  SHA-256 digests `6fa02513…` and `63e74e83…`; `git diff --check` passes. Run the canonical gate
  and then replay `recovery-older-generation`; no candidate cycle qualifies and the legacy writer
  remains sole.
- The documentation-inclusive canonical gate exits **0** with pinned formatting, HLint `No
  hints`, generated-artifact/documentation checks, and warning-clean all-target compilation. Its
  transcript is `/tmp/prodbox-sprint-6.5-cascade-owned-kubeconfig-dev-check.log` at
  `sha256:89a4723df50c243fa643a845a1ebc2b51866fab3ffb89058d075dae55142c2f5`; final documentation
  check, documentation lint, and `git diff --check` also pass. The synchronized executable is
  exact at `sha256:ab46ebb5927905af1bbbb68a0a0f9432f77a3624add3ea5da0fcf315d64bef56`. Replay
  `recovery-older-generation` next; no candidate cycle qualifies and the legacy writer remains
  sole.
- The corrected live replay from **2026-09-08 21:21:32–22:08:12 EDT** builds local image
  `sha256:24f01a01016eecfd5aeaec86f5b5ce34b684fded9f42be6b5fe0f2f7b0ff8184` in **1,129.9 s**,
  publishes Registry manifest
  `sha256:a54e71973b135a99f64f9baca8f05191149e05517f2212c4e84f3c347cd8d2aa`, and imports OCI
  manifest `sha256:435b2a92981c11d5eced4dd57c459e6464151978a7bfd53cc1c05a69db4a7e02` in **95.8 s**;
  retention removes only the immediately superseded manifest/image. Retained-home restore and the
  recovery marker succeed, Phase 2 reaches the private candidate body, and the eager-kubeconfig
  counterexample is live-closed. The run then exits **1** at
  `LifecycleCleanupAuthorityFailed (CleanupRunClientDescriptorRefused
  CleanupRunDescriptorMissing)` before any cleanup node runs; operational credentials are
  preserved. Transcript
  `/tmp/prodbox-sprint-6.5-cascade-owned-kubeconfig-live-recovery-older-generation.log` is
  `sha256:754f5001274b718f919bfb31b43ee35c64e5e441a2f1f51d509b62e28ee1fd07`. Stable
  counterexample `CASCADE-CANDIDATE-PRODUCTION-DESCRIPTOR-MISSING-NOT-CREATE-2026-09-08` owns
  the registration mismatch: the production endpoint's fresh descriptor absence is a typed
  `CleanupRunDescriptorMissing` refusal, but `observeOrCreate` recognizes only descriptor-run
  `NotFound`; the fake Authority returns the latter for fresh state and masks production. Admit
  the exact missing-descriptor answer as the create precondition and make the fake
  production-shaped; no other refusal may authorize creation. No candidate cycle qualifies and
  the legacy writer remains sole.
- That registration mismatch is code-locally closed. `observeOrCreate` admits the exact
  `CleanupRunClientDescriptorRefused CleanupRunDescriptorMissing` answer beside the
  already-admitted descriptor-run `NotFound` answer and no other refusal; the fake Authority now
  emits the production answer for fresh state and an explicit trace regression requires
  observe-before-create. The exact regression passes **1/1**, the complete lifecycle
  cleanup-client group passes **11/11**, and the complete primary suite passes **4,892/4,892 in
  88.01 s**. Warning-clean affected-target compilation and `git diff --check` pass. Transcripts
  `/tmp/prodbox-sprint-6.5-descriptor-missing-registration-{build,focused,group,primary-unit}.log`
  have respective SHA-256 digests `9f6c643f…`, `0c617ade…`, `33ee95ed…`, and `6c79458d…`. Run the
  canonical gate, then replay `recovery-older-generation`; no candidate cycle qualifies and the
  legacy writer remains sole.
- The documentation-inclusive canonical gate exits **0** with pinned formatting, HLint `No
  hints`, generated-artifact/documentation checks, and warning-clean all-target compilation. Its
  transcript is `/tmp/prodbox-sprint-6.5-descriptor-missing-registration-dev-check.log` at
  `sha256:c91133640c4a4bcfcc3638ce69662b2530b76e85e3111b1b1f9a7693e8b24ae0`; final documentation
  check, documentation lint, and `git diff --check` also pass. The synchronized executable is
  exact at `sha256:2197075bc61674cbfee7bd51c5ff1f5c91bff2c5378899b8464084bd50c33e60`. Replay
  `recovery-older-generation` next; no candidate cycle qualifies and the legacy writer remains
  sole.
- That live replay runs from **2026-09-08 22:28:24–23:15:07 EDT** and exits **1** after the full
  retained-home reconcile/restore, recovery marker, Phase 2 dispatch, and private candidate-body
  entry. It builds local image
  `sha256:c304836916070c6e5644438d8732a1a1ea1a38ef84e842fe840cb2f36719b8d6` in **1,135.3 s**, publishes Registry
  manifest `sha256:7556e392751b2983eb1523b0b7c12d786f2df86a6637cf61af658fc6cdfc3ef9`, and imports OCI
  manifest `sha256:5dc5f4678fab120134a68044f6d443b2f603094481b9e5d7343044852c6c752a` in **86.5 s**; retention removes only
  the immediately superseded image/manifest. Production now recognizes missing descriptor as the
  fresh create precondition, so the registration counterexample is live-closed. Descriptor
  creation then copies its exact state to Authority Backup but the required observation is refused
  with `AuthenticatedRolePlainResponseKnown AuthenticatedRoleReplayCapacityExhausted`; the
  response-lost re-observation is refused identically, no cleanup node runs, and operational
  credentials remain preserved. Transcript
  `/tmp/prodbox-sprint-6.5-descriptor-missing-registration-live-recovery-older-generation.log` is
  `sha256:358e8246e4526ad23596d55570688f72f436b2d7408b34b79ac30498d9053f5f`.
  Stable counterexample
  `CASCADE-QUALIFICATION-AUTHORITY-BACKUP-REPLAY-ENVELOPE-UNDERSIZED-2026-09-08` owns the new
  boundary. The role's compiled capacity 18 describes only two nine-request cluster-reconcile
  envelopes; it does not include the supported multi-command restore graph followed by the
  descriptor-bound cleanup state machine. The exact capacity refusal proves 18 retained requests
  were live when the mandatory create read-back attempted request 19. Derive and test the complete
  qualification envelope, widen only Authority Backup through the existing lossless legacy-codec
  migration, and leave deadlines, skew, response bounds, authentication, cleanup transitions, and
  all sibling role capacities unchanged. No candidate cycle qualifies and the legacy writer
  remains sole.
- The Authority Backup correction is now code-local. The role derives a **13-request**
  reconcile/recovery prelude and a **505-request** candidate (`8` registration + `6` claim + `6`
  primary + `59 * 8` node transitions + `13` terminal custody/read-back), then retains
  `2 * (13 + 505) = 1036` entries for one interrupted attempt and its immediate unchanged retry.
  Replay codec **v12** losslessly admits v2–v11 with unchanged response and skew limits. The exact
  59-node descriptor aggregate is measured below 24 KiB; a mixed prelude/aggregate worst-case
  projection fits the new 32 MiB encoded ceiling and fails the former 12 MiB ceiling. Authority
  Backup alone rises from 80 to 144 MiB, preserving the typed host fit. The already-current Target
  Agent 138 MiB bound also receives its missing physical listener closure: Vault's finite request
  ceiling is 192 MiB, sufficient for Base64 plus KV framing. The focused authenticated-transport
  suite passes **37/37** in **0.54 s**; transcript
  `/tmp/prodbox-sprint-6.5-authority-backup-replay-envelope-focused.log` is
  `sha256:6b5906cf5213bb8dfc843762294df155281927b6f43f6718aa80493ad33fe224`.
  Run the full primary suite and canonical gate next, then redeploy and replay
  `recovery-older-generation`; no candidate cycle qualifies and the legacy writer remains sole.
- The complete unit surface is now green on that correction: primary **4,892/4,892** in **89.00
  s** plus auxiliaries **27/27**, **35/35**, and **37/37** in **128.29 s** overall. Its first pass
  correctly exposed two frozen capacity projections that still named the former 80 MiB Authority
  Backup envelope; the current steady workload draw is **10,048 MiB**, and the independently
  frozen one-shot scheduler topology total is **12,608 MiB** after adding the same 64 MiB. Both
  exact capacity regressions pass, and the unchanged scheduler CPU dispositions remain a 245m
  superseded deficit and 5m replacement headroom. The successful full transcript is
  `/tmp/prodbox-sprint-6.5-authority-backup-replay-envelope-unit-rerun.log` at
  `sha256:d03303d34a8e9c56c192d48ab697ecafe33e02f96102d29958b0eb2e74274fa6`. Run the canonical
  gate next, then redeploy and replay `recovery-older-generation`; no candidate cycle qualifies and
  the legacy writer remains sole.
- The documentation-inclusive canonical gate now exits **0** in **599.61 s** with repository
  policy, pinned Fourmolu, HLint `No hints`, generated-artifact/documentation checks, and
  warning-clean all-target compilation. Its transcript is
  `/tmp/prodbox-sprint-6.5-authority-backup-replay-envelope-dev-check-rerun-3.log` at
  `sha256:93e971ad0f9f116825ee71ef422e33bc1b32504c887bff44189dbca174925784`. The synchronized
  `.build/prodbox` is byte-identical to the gate-built executable at
  `sha256:b3b61e02e161515d7076240c7d86d9aa88bab2ffb4763d6133d9cc651fe88dc8`. Replay
  `recovery-older-generation` next on this exact revision; no candidate cycle qualifies and the
  legacy writer remains sole.
- That live recovery rerun runs from **2026-09-09 00:57:38–01:43:54 EDT** and exits **1** after
  reconciling the retained local plane, rebuilding/restoring the older-generation application
  topology, and entering the private candidate body. It builds local image
  `sha256:832746cb4faa0d5ce3889c472945bdb2b936c6ea65b454a740cf2a18fec82a62` in **1,036.5 s**,
  publishes Registry manifest
  `sha256:87b84945e392902468018fdf7678cff22a62298ddb2c61bfcaeeac57f4f5d585`, and imports OCI
  manifest `sha256:3a20574b47e7a6f4c768b2aba5c1b5b06b213142563b4891bd2a2841f092df19` in **96.5 s**;
  retention removes only the immediately superseded manifest/image. Authority Backup deploys with
  the widened envelope, advances and independently reads back the in-force config, and accepts
  descriptor registration/claim beyond the former request-19 refusal, live-closing
  `CASCADE-QUALIFICATION-AUTHORITY-BACKUP-REPLAY-ENVELOPE-UNDERSIZED-2026-09-08`. The expired
  predecessor lease correctly causes claim to retain `CleanupPrimaryRunnerLost`, but the candidate
  unconditionally tries to attach `CleanupPrimarySucceeded`; the exact protected result is
  `LifecycleCleanupPrimaryOutcomeConflict CleanupPrimarySucceeded CleanupPrimaryRunnerLost`.
  Stable counterexample
  `CASCADE-QUALIFICATION-RECOVERY-PRIMARY-OUTCOME-CONFLICT-2026-09-09` owns this resume boundary.
  No cleanup node runs, operational credentials remain preserved, and the supported runtime is
  restored. Transcript
  `/tmp/prodbox-sprint-6.5-authority-backup-replay-envelope-live-recovery-older-generation.log` is
  `sha256:ecb57cf00b744f5e7a47bd31f5074391617db90a10a4566e7fe19c76d7df1731`. Preserve an already
  recorded runner-lost fact and resume its cleanup graph; do not rewrite it as success, allocate a
  replacement run, or weaken primary-outcome conflict detection. The legacy writer remains sole
  and no qualification artifact or activation witness exists.
- The recovery-primary correction is now code-local. After the claim's independent read-back, a
  vacant primary still attaches `CleanupPrimarySucceeded`; any already-recorded constructor is
  preserved and the descriptor-bound driver resumes nodes under that exact run and successor
  fence. Thus runner-lost cannot become success, still makes the final result non-qualifying, and
  no longer strands recover-to-clean before node execution. The existing strict attach conflict
  remains unchanged for callers asserting an outcome. The named regression passes **1/1**, and all
  five non-authorizing candidate regressions pass **5/5**; transcripts
  `/tmp/prodbox-sprint-6.5-recovery-primary-outcome-conflict-{focused-rerun,group}.log` have SHA-256
  digests `c271ca0693851505a67971a6b401d6d9474be1c53936d2b2b86943b34bcb50c8` and
  `59cf043c7e10a781e0257295a00d69f8521c178aca31fc67583e3372d6480d2c`. Run the complete unit
  surface and canonical gate next, then rerun `recovery-older-generation`; the legacy writer
  remains sole and no qualification artifact or activation witness exists.
- The complete unit surface is green on the recovery-primary correction: primary **4,893/4,893**
  in **88.26 s** plus auxiliaries **27/27**, **35/35**, and **37/37** in **127.53 s** overall.
  Transcript `/tmp/prodbox-sprint-6.5-recovery-primary-outcome-conflict-unit.log` is
  `sha256:3ec97bf061eb31c257797e348b8429e7ff6a64ca3fc9cd3e6342c6583ec58721`. Run the canonical
  gate next, then rerun `recovery-older-generation`; the legacy writer remains sole and no
  qualification artifact or activation witness exists.
- The documentation-inclusive canonical gate exits **0** in **610.59 s** with repository policy,
  pinned formatting, HLint `No hints`, generated-artifact/documentation checks, and warning-clean
  all-target compilation. Its transcript is
  `/tmp/prodbox-sprint-6.5-recovery-primary-outcome-conflict-dev-check-rerun.log` at
  `sha256:b0196ce6212a2246b1ce8d820e3ca6094a6b8e228eafd083652302bb82beb92d`. The synchronized
  `.build/prodbox` and gate-built executable are byte-identical at
  `sha256:d49ecac0c70b4363a05448b79f0381c6792d6e89e87a51690308d67aa0fb33f8`. Rerun
  `recovery-older-generation` on this exact correction; the legacy writer remains sole and no
  qualification artifact or activation witness exists.
- That corrected live recovery rerun runs from **2026-09-09 02:11:51–02:59:54 EDT** and exits
  **1** in **2,883.09 s**. It passes the former primary-outcome attachment boundary with the exact
  `CleanupPrimaryRunnerLost` fact preserved, resumes the descriptor-bound cleanup driver, and
  reaches descriptor compaction. Compaction then refuses the still-live run with
  `CleanupRunDescriptorBindingMismatch "descriptor-bound cleanup run retention window has not
  elapsed"`; the mandatory independent re-observation confirms
  `LifecycleCleanupReobservePostStateRejected "descriptor-bound cleanup run remained live after
  compaction"`. Stable counterexample
  `CASCADE-QUALIFICATION-RECOVERY-DESCRIPTOR-RETENTION-WINDOW-2026-09-09` owns this resume boundary.
  The emitted evidence correctly records `aggregate_succeeded=false`,
  `cleanup_residue_absent=false`, and the non-qualifying runner-lost primary; it is not an
  activation witness. Operational credentials remain preserved and the supported runtime is
  restored. The transcript
  `/tmp/prodbox-sprint-6.5-recovery-primary-outcome-conflict-live-recovery-older-generation.log` is
  `sha256:c997cfb25485b47c402611815697039832a5bf533987b4f5fc21651ed2f2657b`; evidence
  `.test-data/qualification/cascade-d13e38d8210241534162d747.evidence` is
  `sha256:366c4ed5baf8539b46ff344e2ff2fa0b595fe5b36d8e5b568ef279aede99312b`. Resolve the
  retention/compaction contract without weakening exact descriptor binding, inventing success, or
  clearing the durable recovered run. The legacy writer remains sole and no qualification artifact
  or activation witness exists.
- The descriptor-retention correction is code-local and preserves the existing eligibility guard.
  The descriptor-bound entry fold independently validates and returns the exact backup-receipted
  live terminal report while `now < lease expiry + retention`, issuing no compaction request; at or
  after that boundary it retains the existing immutable report-blob/tombstone transition and
  mandatory descriptor/report-digest read-back. Nonterminal, runner-lost, failed-node, encode,
  binding, and post-compaction ambiguity arms remain fail-closed. The named regression passes
  **1/1** and the whole lifecycle cleanup-client group passes **12/12**, including eligible
  compaction and lost-response recovery. Transcripts
  `/tmp/prodbox-sprint-6.5-recovery-descriptor-retention-{focused-rerun-3,group}.log` have SHA-256
  digests `0472d05dcac3269fb44d3c37bb31f305e8a523fdc9a28287a049c0b267555f3c` and
  `f8fa32c14425a2998bcb7be282b9b4ea9c2b6746874d87ca939944d2a6452979`. Run the complete unit
  surface and canonical gate next, then replay `recovery-older-generation`; the legacy writer
  remains sole and no qualification artifact or activation witness exists.
- The complete unit surface is green on the descriptor-retention correction: primary
  **4,894/4,894** in **88.26 s** plus auxiliaries **27/27**, **35/35**, and **37/37** in
  **128.47 s** overall. Transcript
  `/tmp/prodbox-sprint-6.5-recovery-descriptor-retention-unit.log` is
  `sha256:1613289d5f0533e48b75657077fc626fe181d61cccc061e1e591628c48cb78f5`. Run the canonical
  gate next, then replay `recovery-older-generation`; the legacy writer remains sole and no
  qualification artifact or activation witness exists.
- The documentation-inclusive canonical gate exits **0** in **612.18 s** with repository policy,
  pinned formatting, HLint `No hints`, generated-artifact/documentation checks, and warning-clean
  all-target compilation. Its transcript is
  `/tmp/prodbox-sprint-6.5-recovery-descriptor-retention-dev-check.log` at
  `sha256:506998eca40db1b3bf7d8b4c5b0a7189b5bfa4953f981bc703744fad90e62ff9`. The synchronized
  `.build/prodbox` and gate-built executable are byte-identical at
  `sha256:15668613910fbd0726477f34f932fa12572a327c242772dd8c0e8283c9a2eae3`. Replay
  `recovery-older-generation` on this exact correction; the legacy writer remains sole and no
  qualification artifact or activation witness exists.
- That live replay runs from **2026-09-09 03:27:52–04:14:52 EDT** and exits **1** in
  **2,820.02 s**. It builds local image
  `sha256:849c24750b5ce356c052f58ddc2b424b80fe37bd42f6663490ce58fc859f83cd` in **1,122.0 s**,
  publishes Registry manifest
  `sha256:33c1a6f90e6ef886d299617eda66bafe2ea38eb46539db4b6926b67a205d92d0`, and imports OCI
  manifest `sha256:6ef4d5cf71436d70edc68854392446fe73c091409b1909eb5391de74aa06e5df`
  in **91.1 s**; retention removes only the immediately superseded manifest/image. The candidate
  returns `LifecycleCleanupReportObserved` without a premature compaction request, live-closing
  `CASCADE-QUALIFICATION-RECOVERY-DESCRIPTOR-RETENTION-WINDOW-2026-09-09`. That exact retained
  report exposes the next earlier node failure: recovery-plane Establish recorded
  `LocalRke2HostObservationRepositoryStateUnobservable (LocalRke2RecoveryStateContradictory
  (LocalRke2InstallMarkersIncomplete (LocalRke2SystemdUnitMarker :| [])))`; read-back and final
  disposition fail, and every dependent AWS/audit/local-terminal node is blocked. Stable
  counterexample `CASCADE-QUALIFICATION-RECOVERY-RKE2-SYSTEMD-MARKER-INCOMPLETE-2026-09-09` owns
  this boundary. Evidence correctly retains `CleanupPrimaryRunnerLost`,
  `aggregate_succeeded=false`, and `cleanup_residue_absent=false`; operational credentials remain
  preserved and this is not an activation witness. Transcript
  `/tmp/prodbox-sprint-6.5-recovery-descriptor-retention-live-recovery-older-generation.log` is
  `sha256:e32d31a2aeb8504d5b6eac636d8d5eb5c7afcb900a01045a068e369a258f673d`; rewritten evidence
  `.test-data/qualification/cascade-d13e38d8210241534162d747.evidence` is
  `sha256:048013e09e7d4ba250fd4957908a3b86de60fadd39040a80dab23d2b84bf41be`. Read-only host
  evidence resolves the exact install-marker observation and durable retry disposition: all eight
  supported-install markers exist, the enabled wants-link
  targets `/usr/local/lib/systemd/system/rke2-server.service`, and `systemctl show` reports that
  exact `FragmentPath`, while the observer alone named the absent
  `/etc/systemd/system/rke2-server.service`. The supported installer and recovery installer do not
  override its systemd directory, so the canonical unit-file marker is corrected to the former
  path; the `/etc/systemd/system/rke2-server.service.d` guardrail directory and enabled wants-link
  remain separate markers. A direct regression pins that distinction, and the focused local-RKE2
  group passes **31/31**. Transcript `/tmp/prodbox-sprint-6.5-rke2-unit-path-focused.log` is
  `sha256:630332d029102150e253e9b0a10f0a1b8b3cb196703787eb18b1f3c775c9a5f7`. The failed report
  remains immutable: same-cycle identity resumes an interrupted nonterminal run, whereas the next
  live correction attempt uses a distinct recovery cycle/run id against the same registered and
  residual resources. Canonical unit passes primary **4,894/4,894** plus auxiliary **27/27**,
  **35/35**, and **37/37**; transcript `/tmp/prodbox-sprint-6.5-rke2-unit-path-unit.log` is
  `sha256:ee7a43deb09fc1b876cdbf57397c10d17076c4a7b415d885b4270e79376ae327`. The canonical quality
  gate passes in **607.43 s** with repository policy, Fourmolu, HLint (`No hints`), generated/docs
  checks, and the all-target warning-clean build; transcript
  `/tmp/prodbox-sprint-6.5-rke2-unit-path-dev-check.log` is
  `sha256:69cd3d6ae2d13a9c8f206e6df5d832e47df02e5dfaaa1ec7082c2ebe7eeeb39e`. The synchronized
  gate-built `.build/prodbox` is
  `sha256:bb89f3035011a4d110a46c71d06e63ae8a2b88a277e9b6e18a823d7cf407236e`. The live
  counterexample remains open until the new run passes. Post-ledger docs generation/lint and
  `git diff --check` also exit zero; their empty transcript
  `/tmp/prodbox-sprint-6.5-rke2-unit-path-post-ledger-docs.log` is the empty SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. The legacy writer remains
  sole and no qualification artifact or activation witness exists.
- The distinct live recovery cycle `recovery-rke2-marker-corrected` runs from **2026-09-09
  04:40:50–05:28:01 EDT** and exits **1** in **2,831.42 s**. It builds corrected local image
  `sha256:cd416df3cb36e422c5287fb8b3118b1535a1189355a035e664e77bc65c058d86` in **1,114.3 s**,
  publishes Registry manifest
  `sha256:c9f744d2d38fece5c5711eedc2100cc8d76e5d5f7d5792f675d8cbbeede828fe`, and imports OCI
  manifest `sha256:e68f2177b34c9996933bfeb56dcca3c254df2a4101a7fdee32b0bafc6d120552`
  in **90.3 s**; retention removes only the immediately superseded manifest/image. The run advances
  past the corrected install observation and exposes the next earlier boundary before cleanup-run
  registration: `LifecycleCleanupHostRunnerFailed HostCleanupRunnerPreparedReadBackMismatch` for
  durable run `cascade-qualification-recovery-rke2-marker-corrected`. Stable counterexample
  `CASCADE-QUALIFICATION-RECOVERY-HOST-PREPARED-READBACK-MISMATCH-2026-09-09` owns this boundary.
  No new qualification evidence file is written; the prior failed evidence remains byte-identical.
  Operational credentials are preserved, and this is not an activation witness. Transcript
  `/tmp/prodbox-sprint-6.5-rke2-unit-path-live-recovery-rke2-marker-corrected.log` is
  `sha256:7da2d804a7b98557da03342f22c9be707ecc697a2ebd3c2b838c69a2b5ab3cd2`. Diagnose the exact
  prepared-intent read-back binding before another live run. The legacy writer remains sole.
- Read-only journal decoding proves that boundary is neither corruption nor a permitted overwrite:
  `active-v1.cbor` is the exact owner-only `HostCleanupPrepared` intent for terminal failed run
  `cascade-qualification-recovery-older-generation`, and the Authority report for that run is
  immutable. The host journal deliberately has one active slot, but its existing exact-completion
  retirement had no production caller and there was no typed terminal-failure retirement. The
  correction keeps that single-writer invariant: a distinct candidate first joins the active run
  to its authenticated descriptor-bound terminal report; an incomplete intent can be archived only
  when that report contains a non-success node, in a canonical owner-only envelope carrying the
  exact active intent, descriptor digest, report bytes, and report digest. The archive is fsynced
  and independently read back before the active link is removed; exact replay closes response loss,
  while a nonterminal/unobservable run or foreign binding leaves the slot occupied. Completed host
  state instead uses its exact completion-receipt retirement. The candidate performs either
  retirement before terminal-report compaction, so the next run never has to infer failure from a
  tombstone. Re-entry for the same run now resumes an exact already-advanced base binding instead of
  requiring the journal to remain `Prepared`, and a true foreign conflict preserves its typed
  `HostCleanupIntentActiveConflict` diagnostic. Focused entry-protocol regressions pass **13/13**;
  `/tmp/prodbox-sprint-6.5-host-intent-terminal-retirement-entry-focused.log` is
  `sha256:e2573e6c9db321abc0053273fd2fb0239370a04cd2e4221d2cbb690bdc700df4`. Focused host-runner
  regressions pass **5/5**;
  `/tmp/prodbox-sprint-6.5-host-intent-terminal-retirement-runner-focused.log` is
  `sha256:37ce28b5995fc243f09d7cd29dfbf328022197672d196b7ae9caeb40ec512946`. Complete canonical
  unit validation passes primary **4,895/4,895** plus auxiliary **27/27**, **35/35**, and **37/37**
  in **121.41 s**; `/tmp/prodbox-sprint-6.5-host-intent-terminal-retirement-unit.log` is
  `sha256:1dfd2b23edc14c8422eb982aac405670dc0e1985363ed5edde85eb98f5e9838a`. The canonical quality
  gate passes in **624.81 s** with repository policy, pinned Fourmolu, HLint (`No hints`), generated
  artifacts/docs, and warning-clean all-target compilation;
  `/tmp/prodbox-sprint-6.5-host-intent-terminal-retirement-dev-check.log` is
  `sha256:cb574c265b2b6b2dd934cbb8ad409db0c234b4825ba1b649061fbb8602b4406b`. The synchronized
  `.build/prodbox` and gate-built executable are byte-identical at
  `sha256:eb4f8caf6707aff779fd8d08b87624e7fa0726ad3c728bdabbe965867ccc6497`. Replay
  `recovery-host-intent-retired`. Post-ledger docs generation/check/lint and `git diff --check`
  also exit zero; `/tmp/prodbox-sprint-6.5-host-intent-terminal-retirement-post-ledger-docs.log`
  is empty at `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. The legacy writer
  remains sole and no activation witness exists.
- The exact live replay `recovery-host-intent-retired` exits **1** in **2,920.19 s** on 2026-09-09.
  It builds local runtime image
  `sha256:6702caa427ce72c8aa5738554741e78f15786b44fb4744808987d238ca411f1f` in **1,122.6 s**,
  publishes Registry manifest
  `sha256:bb01db1831ae1213bfc2cdcde877520e78160e61d60abc54633859930bec5dd5`, and imports OCI
  manifest `sha256:7c193a01d9859c4d6d427ab12a564e490ac6593f75ee5b4268c16c94a3ef6ad3` in **89.9 s**;
  retention removes only the immediately superseded manifest/image. The distinct run is admitted,
  returns `LifecycleCleanupReportObserved`, and writes evidence
  `.test-data/qualification/cascade-ad4d0cd8c3440ba0cf6cfd7d.evidence` at file SHA-256
  `fa673fdf480580266e124ba6cb4cd073480dd99cfc90c5532543ee66dbb464c9` with governed evidence
  digest `ff273c9bc872b5b7ee3996691da8a3cbb07cac49834be8cb730ca211801c39fc`. There is no
  `active-v1.cbor`; the formerly blocking run and this newly terminal run are each retained as one
  immutable `failed-*.cbor` archive, live-closing
  `CASCADE-QUALIFICATION-RECOVERY-HOST-PREPARED-READBACK-MISMATCH-2026-09-09` without overwriting
  either failure. The graph preserves `CleanupPrimaryRunnerLost`; recovery Establish succeeds, but
  initial read-back fails generically as `cleanup recovery plane is not initially ready`, final
  disposition reports not established, and every AWS/audit/local-terminal successor is blocked.
  Operational credentials remain preserved and this is not an activation witness. Transcript
  `/tmp/prodbox-sprint-6.5-host-intent-terminal-retirement-live-recovery-host-intent-retired.log`
  is `sha256:d5b7161d7043788789c3444925c06172b924c8f05cbc2f2c6661f6c8d5dffbc6`. Fresh read-only exact
  object, Vault, and RBAC probes find no current unavailable component, so no semantic correction
  is licensed from the generic report. Stable counterexample
  `CASCADE-QUALIFICATION-RECOVERY-INITIAL-FAILURE-DIAGNOSTIC-LOST-2026-09-09` owns the loss of the
  public component identity/kind failures in `Execution`; expose those bounded non-authorizing
  facts for both initial and final failure outcomes before the next distinct live replay. The
  legacy writer remains sole.
- The diagnostic-loss counterexample is closed code-locally without changing recovery admission,
  component predicates, or readiness evidence. `RecoveryPlane` now renders only the existing
  normalized fixed-profile component identity and `missing`, `partial`, `unavailable`, or
  `unobservable` kind, caps that projection at 1,024 characters, and structurally cannot include
  the erased raw observer detail. `Execution` appends that view to both initial-read-back and final
  recovery failure node outcomes; success remains reachable only through the unchanged typed Ready
  evidence. The focused recovery-plane group passes **6/6** in **0.77 s**;
  `/tmp/prodbox-sprint-6.5-recovery-component-diagnostic-focused.log` is
  `sha256:2c97994318dad16555af4dc85602a252ad0e687afcf0906c14b5e08d76938897`, and its build
  transcript is
  `sha256:4862609a630bed4bead97a13e6ad3de75f7ec81654175e212b6714dd24da34a1`. Complete
  canonical unit validation passes primary **4,896/4,896** plus auxiliary **27/27**, **35/35**,
  and **37/37** in **124.20 s**;
  `/tmp/prodbox-sprint-6.5-recovery-component-diagnostic-unit.log` is
  `sha256:fb3316e9719406656b8433e168383a5d17b9c945681c029b9dd9b2c204a4fba0`. The canonical
  quality gate passes in **614.81 s** with repository policy, pinned Fourmolu, HLint (`No hints`),
  generated artifacts/docs, and warning-clean all-target compilation;
  `/tmp/prodbox-sprint-6.5-recovery-component-diagnostic-dev-check.log` is
  `sha256:a3e44bf891c108614a876992364730af55f857971291098306914e9e02f4f74d`. The synchronized
  `.build/prodbox` and gate-built executable are byte-identical at
  `sha256:e97c9224d982e5c101726fd37a9db60dd865f44af4676ecaa9e719593471adb5`. Replay under the
  distinct cycle `recovery-component-diagnostic`; the legacy writer remains sole and no activation
  witness exists. Post-ledger docs generation/check/lint and `git diff --check` also exit zero;
  `/tmp/prodbox-sprint-6.5-recovery-component-diagnostic-post-ledger-docs.log` is empty at
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
- The distinct live replay `recovery-component-diagnostic` exits **1** in **2,987.81 s** on
  2026-09-09. It builds local runtime image
  `sha256:a574161b4ed1cee34a6585b168bf67a865cf32061967642236782b2f25614ff7` in **1,134.4 s**,
  publishes Registry manifest
  `sha256:1c1db4a4b64b8da1d0f6643838f9fc625e9436d8efd65960f96a4117b42f8285`, and imports OCI
  manifest `sha256:f8e095f247a6ba11f08b0adbdbf08d44dab0d16011133c7fe4ded63571749172`
  in **93.5 s**; retention removes only the immediately superseded manifest/image. Retained-home
  preflight reaches a ready external-proof edge and enters the recovery-mode body. Durable run
  `cascade-qualification-recovery-component-diagnostic` returns graph digest
  `22cec8a9f49d3e640b55f400ec0d3c21475428cbd08ecf0a542ec3e6142954b6` with preserved primary
  `CleanupPrimaryRunnerLost`. Recovery Establish succeeds; both initial read-back and final
  disposition now fail exactly with `component/cluster_base:missing`, and every AWS/audit/local
  terminal successor remains blocked. Evidence
  `.test-data/qualification/cascade-4cd87b56be0115497bf809ac.evidence` has file SHA-256
  `9a37a7e0f9bf21b3aae48044d64224142538a29c5d4660251695b5ce111e0b09` and governed digest
  `05a98bd272065d0bb32ac06203cf527765a4f559a5597e7705edba48b039102e`. The terminal host intent
  is archived and no active link remains; operational credentials are preserved. Transcript
  `/tmp/prodbox-sprint-6.5-recovery-component-diagnostic-live-recovery-component-diagnostic.log`
  is `sha256:f998d532f626c7707686aa8e897a564981c9724f05c376343c1a50298a92478a`.
  This live-closes
  `CASCADE-QUALIFICATION-RECOVERY-INITIAL-FAILURE-DIAGNOSTIC-LOST-2026-09-09`, but is not a
  qualification or activation witness. Stable counterexample
  `CASCADE-QUALIFICATION-RECOVERY-CLUSTER-BASE-MISSING-2026-09-09` owns the newly visible exact
  boundary. Diagnose which independent cluster-base observation produced absence and whether
  Establish can legitimately succeed without repairing it; do not infer readiness from later
  point probes or conflate local RKE2 with the missing older EKS target. The legacy writer remains
  sole.
- The exact diagnosis is cross-phase identity drift rather than local RKE2 absence. The host
  endpoint commits the Healthy cluster-base candidate against the descriptor-bound Establish node
  while that exact attempt is Running. `RecoveryPlaneIdentity` also binds the digest of currently
  nonterminal recovery capabilities; when the immediately following read-back re-derived that
  identity from the new run state, Establish had become terminal, so it selected a different
  exact-keyed host-observation slot and honestly returned `missing`. The correction preserves the
  original identity rather than weakening it: from the read-back node's sole exact attempted
  predecessor, it validates the completed Establish operation, attempt, and outcome against the
  authoritative run, purely reconstructs that one node as Running, and re-derives the
  Establish-time requirement through the committed descriptor. Both Cascade and ExplicitPerRun
  regressions now require the serialized identity seen by initial and final observation to be
  byte-identical to Establish. The focused interpreter group passes **7/7** in **2.56 s**;
  `/tmp/prodbox-sprint-6.5-recovery-establish-identity-focused.log` is
  `sha256:92783dcc8757a03136677fa95dacca7b44a086d879fa9cee5a64cafa6b1d6ffa`, and its warning-clean
  build transcript is
  `sha256:e787f56e5165604da52baf5793c02dadb473262c5744d8e45f21cb49f864c129`. Complete canonical
  unit validation passes primary **4,897/4,897** plus auxiliary **27/27**, **35/35**, and
  **37/37** in **131.34 s**;
  `/tmp/prodbox-sprint-6.5-recovery-establish-identity-unit.log` is
  `sha256:a8c1785af8a9dd0d7ae4344844e4f8f96ff253e2905e40375803f386a9c754d5`. Canonical
  `prodbox dev check` passes in **626.27 s** with repository policy, pinned Fourmolu, HLint
  (`No hints`), generated artifacts/docs, and warning-clean all-target compilation;
  `/tmp/prodbox-sprint-6.5-recovery-establish-identity-dev-check-rerun.log` is
  `sha256:b2d7ce7b9e852702ffd20233d29253106e84462d844fd8bac62a633dc7f54601`.
  The synchronized `.build/prodbox` and gate-built executable are byte-identical at
  `sha256:e0b8c2884d58cbc0a948d37625d7f0f709d2583e29a31ad8b46da5d5fd81458c`. Post-ledger docs
  generation/check/lint and `git diff --check` also exit zero;
  `/tmp/prodbox-sprint-6.5-recovery-establish-identity-post-ledger-docs.log` is empty at
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. A distinct live
  `recovery-establish-identity` replay remains pending. The legacy writer remains sole and no
  activation witness exists.
- The distinct live `recovery-establish-identity` replay exits **1** in **3,517.47 s** on
  2026-09-09. It builds local runtime image
  `sha256:8a7b9a4c68992a6e78e4f26cc33679476399da01f75d96ec7f01e77a0a7f9940` in **1,135.2 s**,
  publishes Registry manifest
  `sha256:46721e1a08ca524fc4c8f8e4fdc3241125005530e946ea0d2e8145ca64d2fc2e`, and imports OCI
  manifest `sha256:64dc2c5b794e04d542e61a1f929a1080da4890fae26eba5cecad7a2b1b15463e`
  in **99.2 s**; retention removes only the immediately superseded manifest/image. Retained-home
  preflight reaches a ready external-proof edge and enters recovery mode. Durable run
  `cascade-qualification-recovery-establish-identity` returns graph digest
  `4e4c1535513b6496b0b5687ad27e36b7423162712fc564dfb913ab9bd0bba04d`. Recovery Establish
  attempt `5acc9e3c...`, initial read-back attempt `af56add7...`, and final disposition attempt
  `f72e7d15...` all complete `CleanupNodeSucceeded`, live-closing
  `CASCADE-QUALIFICATION-RECOVERY-CLUSTER-BASE-MISSING-2026-09-09` and proving the Establish-time
  identity correction. The graph advances into AWS teardown but is not qualifying: its primary is
  `CleanupPrimaryRunnerLost`, and later nodes expose missing stack-reader/Provider and EKS-drain
  bindings plus exact AWS family/DNS unobservability. Evidence
  `.test-data/qualification/cascade-9f57b606c2c7a82630d1c9d0.evidence` has file SHA-256
  `f7e5d71f0e06b6cb26b108d3e1bef7b0d8f54a746721d9a16761df4a44e27569` and governed digest
  `27c3020adf792bdeb5aa762da587cee83f2808d392163554998dea3e0891d0b2`. The terminal host intent
  is archived with no active link, and operational credentials are preserved. Transcript
  `/tmp/prodbox-sprint-6.5-recovery-establish-identity-live-recovery-establish-identity.log` is
  `sha256:a501a1fd7f882c626a6687c35cd8fd39bea13937132b8890f08c2f606b06a94b`.
- The earliest independent defect is the fresh primary ordering, not the lease kernel. A cascade
  descriptor must remain stable across re-entry, so its initial run encodes the declared lease
  window relative to zero rather than sampling a clock into program identity.
  `runCascadeCandidate` then claims that fresh run at current epoch before it attaches
  `CleanupPrimarySucceeded`; ordinary expired-lease takeover correctly records
  `CleanupPrimaryRunnerLost` into the vacant immutable slot. Stable counterexample
  `CASCADE-QUALIFICATION-FRESH-DECLARED-LEASE-RUNNER-LOST-2026-09-09` owns the correction: attach
  the cascade's intrinsic primary-success fact while the freshly registered exact owner/fence is
  still authoritative, then claim the active epoch lease. A resume with any recorded primary
  outcome must still skip attachment and preserve it. Do not change `claimCleanupRun`, lease
  expiry/fencing, descriptor determinism, or any AWS node in this correction.
- That correction is code-local to the non-public candidate drive. A fresh vacant run now commits
  `CleanupPrimarySucceeded` through the existing exact owner/fence transition before its epoch-time
  claim; a resumed run with any existing primary constructor skips attachment exactly as before.
  The lease kernel, descriptor bytes, stable run identity, fencing, and AWS graph are unchanged.
  The regression exercises both orders against the real pure kernel: attach-first preserves
  success across the expired declared-window claim, while the claim-first mutation records
  runner-lost. The focused candidate group passes **6/6** in **0.16 s**;
  `/tmp/prodbox-sprint-6.5-recovery-primary-activation-focused.log` is
  `sha256:3eb901286c8a5b00c3e5b3988bc0c71c83cec47bc66630e95fd05ecbe97f3150`, and its warning-clean
  build transcript is
  `sha256:d7c3d5bfaa5bd01397ed49e1d5861531b6b2d507d5274540a30a7ddb3e2365d1`.
  Complete unit validation passes primary **4898/4898** plus auxiliaries **27/27**, **35/35**, and
  **37/37** in **134.52 s** at
  `/tmp/prodbox-sprint-6.5-recovery-primary-activation-unit.log`,
  `sha256:9f79bba314d843aa76d010d1e73762913cf1c46dbf0a4a36540781c2d8ec0dc3`. Canonical quality
  validation passes in **617.23 s** at
  `/tmp/prodbox-sprint-6.5-recovery-primary-activation-dev-check.log`,
  `sha256:ea9689f457d102152b4e50e9d1c800865af79e029ab2de9b19319e779d79b624`, with pinned formatting,
  HLint `No hints`, policy and generated-document checks, and warning-clean all-target compilation.
  The gate-built and installed executables are byte-identical at
  `sha256:fa63678c7a1739153db905a9c2faa0e37a03f0f22ccb377bc81fb631e2bda398`. The distinct live replay
  is next. Ledger-inclusive generated-document check, documentation lint, and `git diff --check`
  also pass with empty output at
  `/tmp/prodbox-sprint-6.5-recovery-primary-activation-post-ledger-docs.log`,
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
- The distinct live `recovery-primary-activation` replay exits **1** after **3630.35 s** at
  `/tmp/prodbox-sprint-6.5-recovery-primary-activation-live-recovery-primary-activation.log`,
  `sha256:01d8ff45e6314b3bab5c8102fa67e56e9dc01f4bf94938ac0161b13bbdecb9cb`. It builds local image
  `sha256:3b95350b0f83238c327d710ded274d68ef8de73b48ee9d23075a80e83a21a131` in **1129.3 s**,
  publishes Registry manifest
  `sha256:f6eba82edf712c94bb09f677a60f21efe906af378ccbe17fb8f05468a5ff2d69`, and imports OCI
  manifest `sha256:24e73464e7b7d9a1bbcd03637fe747d1095ff1d2c148a428b73088ba45425671`
  in **91.8 s**. Retention removes only the preceding Registry manifest `sha256:46721e1a...` and
  local image `sha256:8a7b9a4c...`. Durable run
  `cascade-qualification-recovery-primary-activation` returns graph digest
  `0264613f3d190d47db8474fb655ebbbd796f74ab0ac4874a425419100057f8a0`. Recovery Establish
  attempt `4b595bcb...`, read-back attempt `8c152bbd...`, and final disposition attempt
  `83bf6f2c...` all complete `CleanupNodeSucceeded`; critically, the report's immutable primary is
  now `CleanupPrimarySucceeded`, live-closing
  `CASCADE-QUALIFICATION-FRESH-DECLARED-LEASE-RUNNER-LOST-2026-09-09` without changing the lease
  kernel or descriptor identity. Evidence
  `.test-data/qualification/cascade-c6cf62586055818910e07d71.evidence` has file SHA-256
  `795f5f4a370e354c3d27e50c1733bb03eba96d8850c9baf2ed1392f5e5d58f6e` and governed digest
  `12faa6980b74d3e36d2f213b218a7a40b29081d122c2d2cedd98c2dec440e82b`. The terminal host intent
  is archived as `failed-b524d710...-a4b52a42....cbor`, no `active-v1` link remains, and
  operational credentials are preserved. The same report now cleanly exposes the later
  independent EBS/IAM/load-balancer-family, stack-reader, EKS-drain, and DNS01 boundaries;
  diagnose their dependency order before admitting the next correction.
- Source inspection selects the shared stack-reader boundary before the independent EKS-drain and
  DNS01 failures. `observeAwsRegisteredTarget` sends a generic stack's initial read through
  `awsRegisteredTargetReadStackProviderBinding`; production binds that field to the stack-reader
  repository, but the graph cannot commit its bundle until after checkpoint recovery. The same
  field is also addressed by the final absence node's operation id although
  `CommitAwsStackReaderBundle` stores the bundle under the future reconcile operation. The
  checkpoint recovery read-back further re-enters that final-reader path before bundle commit.
  Stable counterexample
  `CASCADE-QUALIFICATION-STACK-READER-ROLE-IDENTITY-MISMATCH-2026-09-09` owns only this correction:
  pre-bundle observation must reconstruct the Provider configuration from the separately retained
  stack-creation binding, reconcile and final absence must consume the independently read-back
  stack-reader bundle under its reconcile identity, and checkpoint no-restore read-back must use
  the pre-bundle observation path. The graph, repository/wire schemas, Provider effects, and all
  later failure boundaries remain unchanged.
- That correction is now code-local. `AwsRegisteredTargetInterpreter` carries separate creation-
  binding and stack-reader-bundle readers. Initial generic-stack observation uses the former;
  reconcile and terminal absence use the latter, with the terminal node deriving the compiled
  reconcile operation id rather than addressing the bundle by its own read-back id. Checkpoint
  recovery re-observes through the pre-bundle path. Production reconstructs creation bindings only
  from the retained stack-generation and exact creation-binding read-back; no fallback or process-
  local handoff was added. The registered-target group passes **15/15** and the checkpoint group
  passes **10/10** at `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-focused.log`,
  `sha256:1039cd1d58f662ecc0f18e8d10e1a6691ed7df40f464c45aac0f318c76dcfcca`. Warning-clean complete
  unit-target compilation passes in **148.78 s** at
  `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-focused-build.log`,
  `sha256:3ac619715789b1858d88e4b4e32689b11236d5837bec69a2f4a7fd13f0768477`. Complete unit validation
  passes primary **4900/4900** and auxiliaries **27/35/37** in **140.51 s** at
  `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-unit.log`,
  `sha256:115d4916000e90db06e339d8fa4ded8692d6d63d9e4d4f125edf976248b7da07`. Canonical `prodbox dev
  check` passes in **621.68 s** at
  `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-dev-check.log`,
  `sha256:e05d5a6a4d97440efde1ddeb956de8623d013869e6daece9dfeaf20ca63c7ab9`, including pinned
  formatting, HLint `No hints`, documentation/generated-artifact policy, and warning-clean
  all-target compilation. The gate-built executable and synchronized `.build/prodbox` are
  byte-identical at
  `sha256:c0bfc872f8ae8a9709fb5f22315eb94961f3812b3d10411f2d8d8f67f2912b25`. Post-ledger generated
  documentation, documentation policy/lint, and `git diff --check` pass with empty transcript
  `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-post-ledger-docs.log`,
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. The distinct live replay is
  next.
- The live `stack-reader-role-identity` command exits **1** in **4,884.84 s** before candidate
  dispatch because that label does not carry the required `recovery-` prefix and therefore selects
  `CascadeQualificationProvisionFresh`. The moving `ubuntu:24.04` tag changed upstream digest
  during the run, so its first image/Registry/OCI identities
  `8575da38641d3d0aaa964fb5373bfa2e5e4d1cc9333764fe273ef816622f19f5` /
  `88fcc2e925b86e8c89c472daccf98e6dbe06bc752211d536c93ed7aade3fb4c3` /
  `453364efb199c9f43405198fddc9097cd4a6a4ed7b2944c1468cd361cbd56377` were superseded through the
  supported reconcile by
  `0b783fae7e6727596b002b5d7469d5cde8566af0d110123e33826bf7bafc1e08` /
  `9249bdc46dce8bbd15d45a132861a9e843f7cca7fd8f896b400fe38ceddb6080` /
  `0d658791d4655951ec1ec6d06d07954dd02b0fe47ef8fff49fca01dd55c3e74a`; retention removed only the
  immediately superseded pair. Fresh EKS create then re-exposes the already-registered
  `CASCADE-QUALIFICATION-BOOTSTRAP-PRECEDES-RESIDUE-RECOVERY-2026-09-08` boundary: AWS returns exact
  409 `EntityAlreadyExists` for deterministic role
  `prodbox-aws-eks-test-aws-eks-test-cluster-cluster-role` after Pulumi creates an Internet gateway
  and two public subnets. The committed generation remains `AwsStackCreationCommitCreated`, a
  stack may exist, exact cleanup is not proved, and operational credentials are preserved. No
  qualification evidence or host-cleanup intent is emitted because the private candidate was not
  entered. Transcript
  `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-live-stack-reader-role-identity.log` is
  `sha256:df81a7d93d2a32642d4add44ac50090f1913052fb927e2a1170c81fc4e01b9e4`. This is a
  command-selection correction, not a code change: run the distinct correctly prefixed cycle
  `recovery-stack-reader-role-identity` against the retained generation; no local gate is
  invalidated. Ledger-inclusive generated documentation, documentation policy/lint, and `git diff
  --check` pass with empty transcript
  `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-pre-recovery-docs.log`,
  `sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
- The correctly prefixed live `recovery-stack-reader-role-identity` cycle exits **1** on 2026-09-09
  after entering the private candidate. Retained-home reconciliation is exact on local image
  `sha256:0b783fae7e6727596b002b5d7469d5cde8566af0d110123e33826bf7bafc1e08` and Registry manifest
  `sha256:9249bdc46dce8bbd15d45a132861a9e843f7cca7fd8f896b400fe38ceddb6080`.
  Durable run `cascade-qualification-recovery-stack-reader-role-identity` returns graph digest
  `b1bba8fc0bf0d9c706cd8a9f57d5be1a9bdd58231b5ed6f736e5ede992121a7c` with preserved primary
  `CleanupPrimarySucceeded`; recovery Establish, initial read-back, and final disposition all
  complete `CleanupNodeSucceeded`. `aws-eks/observe` also succeeds, live-proving the prior reader-
  role split on that arm. The earliest remaining generic-stack failure is
  `aws-eks-subzone/observe`: its selected generation reconstructs the original
  `ReconcileDesiredPresent` creation scope, then the older absent-cleanup reader rejects that scope
  as `AwsStackCreationFieldInvalid "lifecycle operation mismatch"` before any Provider observation.
  Stable counterexample
  `CASCADE-QUALIFICATION-CREATION-BINDING-SCOPE-OPERATION-MISMATCH-2026-09-09` owns only a distinct
  creation-scope reader and the proof that present and absent scope readers remain disjoint. Later
  checkpoint-operation, Provider-request, EKS-drain, DNS01, EBS, IAM, and load-balancer-family
  failures remain unlicensed. Evidence
  `.test-data/qualification/cascade-5a97a31848129b57c30ec023.evidence` has file SHA-256
  `6500b21f04c52201620097a55725a63dfa8ca1541e4a36351a28ea2832fb34a1` and governed digest
  `317c03d3f6a5dd3b444bcd660247a563800874be38418b90a772a6dbd90aca2e`. Transcript
  `/tmp/prodbox-sprint-6.5-stack-reader-role-identity-live-recovery-stack-reader-role-identity.log`
  is `sha256:6e09c61c601d4ae3c62bc70fa97ce8dfbfe6038caead4ecbe69ae28fb185a0cb`.
- The creation-binding lifecycle-operation correction is code-local and validated. The Authority
  repository exposes distinct creation- and cleanup-scope read helpers; each derives its identity
  only after validating its own `ReconcileDesiredPresent` or `ReconcileDesiredAbsent` operation,
  and the bidirectional negative cases prove neither accepts the other's scope. Production selected-
  generation reconstruction calls only the creation helper. No graph edge, wire schema, Provider
  intent/effect, or later target boundary changes. The focused repository group passes **11/11** at
  `/tmp/prodbox-sprint-6.5-creation-binding-scope-focused.log`,
  `sha256:c5a03916c2a991336f97b690902edd2fcb26861ed176255f33bc073153047094`.
  Complete unit validation passes primary **4900/4900** plus auxiliaries **27/27**, **35/35**, and
  **37/37** at `/tmp/prodbox-sprint-6.5-creation-binding-scope-unit.log`,
  `sha256:291bcfccbe9fd40c72041877094a6313f3f80e5bb5d86cc72f8dad9303790f03`.
  Canonical `prodbox dev check` passes with pinned formatting, HLint `No hints`, repository and
  generated-document policy, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-creation-binding-scope-dev-check.log`,
  `sha256:117975441eb8333d81d7882cb7f8ba2d18b2f1a48c32c869637eba51245a1661`.
  The gate-built and synchronized `.build/prodbox` are byte-identical at
  `sha256:502995be0f2d9e949b8d73812d1240ff0b27ed7b7aea7a3ed8070a05f7e08459`. Run the distinct
  live recovery cycle `recovery-creation-binding-scope` next; the legacy writer remains sole.
- The distinct live `recovery-creation-binding-scope` cycle exits **1** on 2026-09-09 after entering
  the private candidate, but it live-proves the creation-reader correction. Durable run
  `cascade-qualification-recovery-creation-binding-scope` preserves primary
  `CleanupPrimarySucceeded`; recovery Establish, initial read-back, and final disposition all
  succeed. `aws-eks/observe` remains successful, and `aws-eks-subzone/observe` crosses the former
  lifecycle-operation mismatch before refusing at
  `AwsRegisteredTargetStackBindingInvalid (AwsStackNativeFamilyInvalid
  AwsNativeStackFamilyZoneMissing)`. The same zone-less descriptor later refuses DNS01 observation
  as `Dns01ChallengeHostedZoneMissing`. Stable counterexample
  `CASCADE-QUALIFICATION-AWS-DNS-ZONE-RESOLUTION-MISSING-2026-09-09` owns only resolution of the
  exact AWS-substrate zone through the existing config-or-live-stack-output read path before
  descriptor compilation and key-specific projection of that shared DNS coordinate into the
  subzone-native Provider ref. It does not license inferred identity, relaxed family validation,
  or changes to later EKS checkpoint, EKS-drain, Provider-request, EBS, IAM, or load-balancer-
  family boundaries.
  Graph digest is
  `c7f28c23624598cc84470db99ba49de1e18f5e70e945cb9ceea736f6f15bf903`. Evidence
  `.test-data/qualification/cascade-1fc747f5ec62edd274956a7d.evidence` has governed digest
  `c6c4e8d18e6ab6d4d565c8a86d2a5d91073bd3cf324c273e2b033f9ea5a60b28` and file SHA-256
  `a33b6097287e89b545075535811106638b84ff74fa8d135229fba9854aac8d31`. Transcript
  `/tmp/prodbox-sprint-6.5-creation-binding-scope-live-recovery-creation-binding-scope.log` is
  `sha256:ff6f153914f94e7947b62d95aadc5a7fc622ea12e072c1c51212a113b4de34fa`.
- The AWS DNS-zone resolution correction is code-local and validated. Qualification uses the
  existing typed config-or-live-`aws-eks-subzone`-output resolver before descriptor compilation;
  the compiled scope therefore retains one exact hosted-zone ID even when the authored override
  is intentionally empty. The native-family adapter projects that DNS coordinate into only the
  subzone ref, continues to require it there, and proves EKS/test refs remain zone-free. No
  Provider effect, graph edge, wire schema, identity inference, or later target behavior changes.
  The exact adapter regression passes **11/11** at
  `/tmp/prodbox-sprint-6.5-aws-dns-zone-resolution-focused.log`,
  `sha256:426b77774fa6b539559ea4d6476a14fdef604ce6618ac20612ae15c7847798a5`. Complete unit
  validation passes primary **4901/4901** plus auxiliaries **27/27**, **35/35**, and **37/37** at
  `/tmp/prodbox-sprint-6.5-aws-dns-zone-resolution-unit.log`,
  `sha256:72d22d8796214fbe52bf3530b386965c75adbd2ac23ab5ab573b0a419aa9e992`. Canonical `prodbox
  dev check` passes with pinned formatting, HLint `No hints`, repository/generated-document
  policy, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-aws-dns-zone-resolution-dev-check.log`,
  `sha256:c4253647dfa59059e010c5d33f369f51c6d3f8729b37eece01ed095075fb956f`. The gate-built and
  synchronized `.build/prodbox` are byte-identical at
  `sha256:2a3016965253e40bb0e097eb8078537535a5b073f4539530c4ef925757435873`. Run distinct live
  recovery cycle `recovery-aws-dns-zone-resolution` next; the legacy writer remains sole.
- Live `recovery-aws-dns-zone-resolution` exits **1** on 2026-09-09 but proves the DNS-zone
  resolution/projection correction. The run builds local image
  `sha256:7b5e5cda221e293f24e42339c528ea0bde4c1ce0ac5021d162768b26f6fdb84c` in **1,122.3 s**,
  publishes Registry manifest
  `sha256:4039c02d64ea4d83a565163cedaf7ce318f283d2a7bb38661ce758f49f844d54`, and imports OCI
  manifest `sha256:9863418c72246666918510010b73f90f99e926b7fcdfb01837ed21b7ca797e69` in **97.9 s**;
  retention removes only the immediately superseded manifest/image. In the private graph,
  `aws-eks-subzone/observe` and `dns-aws-dns01-challenge-records/observe` both cross their former
  typed zone-missing refusals and reach Provider observation, where current independent failures
  classify them as unobservable. Recovery Establish and initial read-back succeed, but final
  disposition read-back fails with
  `RecoveryPlaneBindingObservationScopeMismatch`: its expected scope contains exact
  `HostedZoneId "Z00231272QFGWVE1AJI2G"` while the retained recovery binding lost that coordinate.
  Stable counterexample `CASCADE-QUALIFICATION-RECOVERY-PLANE-DNS-ZONE-SCOPE-LOSS-2026-09-09` owns
  only preservation and exact read-back of the optional DNS coordinate across recovery-plane
  binding persistence; it does not license relaxed scope equality or changes to later target
  boundaries. Durable run `cascade-qualification-recovery-aws-dns-zone-resolution` preserves
  primary `CleanupPrimarySucceeded` and returns graph digest
  `23715076c1b13ca4363e601c378395ef8c54dd136384231e3dbf586db1e9dc7a`. Evidence
  `.test-data/qualification/cascade-7b4fcce84437351d199e1a1f.evidence` has governed digest
  `5dc4a9b72206c2e639bf25ff3d528ef1ea92f2f62c2a84b62446f9f5cdaf950c` and file SHA-256
  `a4a9af96bb9eb92d8b002da80b392083c85999527b75bc8da8bb6bf52bd65df9`. Transcript
  `/tmp/prodbox-sprint-6.5-aws-dns-zone-resolution-live-recovery-aws-dns-zone-resolution.log` is
  `sha256:f9f0e2d4cb9c27bb76f5388d312ac6237a5193116bf5f6979c9f698436f08278`.
- The recovery-plane DNS-zone scope counterexample is closed code-locally without changing
  scope equality or any observer. `RecoveryPlaneIdentityWire` v2 retains the optional hosted-zone
  key and reconstructs the exact zone-bearing scope on restart. The bounded canonical decoder
  admits the prior v1 shape only through its separate exact legacy layout and upgrades it to the
  zoneless scope it originally represented; it cannot attach a zone to legacy evidence. Focused
  codec, Authority-repository, and descriptor-bound restart validation passes **19/19** at
  `/tmp/prodbox-sprint-6.5-recovery-plane-dns-scope-focused.log`,
  `sha256:e7c0ea3ec16fa02dae3dfdf4b9a290ad0bb8b0ffb9d1412dfca9e5d52145b1e3`. Complete unit
  validation passes primary **4901/4901** plus auxiliaries **27/27**, **35/35**, and **37/37** at
  `/tmp/prodbox-sprint-6.5-recovery-plane-dns-scope-unit.log`,
  `sha256:13029b1ccf615559f86e78fd98a3cae4ffb258c2d3891058edd53115657d8822`. Canonical `prodbox
  dev check` passes with pinned formatting, HLint `No hints`, repository/generated-document policy,
  and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-recovery-plane-dns-scope-dev-check.log`,
  `sha256:5b8881c735e18dd3466153d8775395d001b4e25c010041ef1bc55b35cd8c7155`. The synchronized
  executable is `sha256:cabedfe110c505645a2038ec80ac25573c16c46d380d3e216f72356a667b19d2`.
  Run distinct live cycle `recovery-recovery-plane-dns-zone-scope` next; the legacy public writer
  remains sole.
- Live `recovery-recovery-plane-dns-zone-scope` exits **1** on 2026-09-09 but proves the
  RecoveryPlane identity correction. The run builds local image
  `sha256:81819e8bf307d25804ef09f7f64fd4b806b5d6e872d30733fd8dc1533b41e521` in **1,136.3 s**,
  publishes Registry manifest
  `sha256:1cf76ba1115d1b15f3f62c633a2cafd83046ee60d4af732373548a50e6bcd179`, and imports OCI
  manifest `sha256:528aec2f2f9823e619d34826bb497f348a0b291929ff76afb504f281489df3fd` in **96.6 s**;
  retention removes only the immediately superseded manifest/image. Recovery Establish, initial
  read-back, and final disposition all succeed under the exact zone-bearing scope. The EKS target
  and checkpoint pair also observe successfully, and checkpoint restore succeeds without mutation
  because its primary copy is already current. Mandatory checkpoint recovery read-back then fails
  at `CheckpointAuthorityOperationUnknown`: it requires an admission key that correctly was never
  created on that no-mutation arm. Stable counterexample
  `CASCADE-QUALIFICATION-AWS-EKS-CHECKPOINT-NO-MUTATION-READBACK-2026-09-09` owns only direct
  recovery read-back from a fresh exact current primary pair; missing-primary recovery from a usable
  backup must still bind and read back the exact admitted restore operation. Durable run
  `cascade-qualification-recovery-recovery-plane-dns-zone-scope` preserves primary
  `CleanupPrimarySucceeded` and graph digest
  `48e42482305e3a5c73e31672ac003d21f4db4e40504c8db2dc9ce85c3f8cbda3`. Evidence
  `.test-data/qualification/cascade-fa91219591cd00541d1c37bb.evidence` has governed digest
  `22f0d36d43a5d0f17d19e8120aefc0ec057ea5af8ad292acb270a620e1527305` and file SHA-256
  `d4d6c0089ae1f89af17f003f7a24f5747a0277b9a7671b23515a401ecd49af59`. Transcript
  `/tmp/prodbox-sprint-6.5-recovery-plane-dns-scope-live-recovery-recovery-plane-dns-zone-scope.log`
  is `sha256:69e2df08bec52fa0240c98fb1795169fd34ac85847099f006a4c4d76b6f81daa`. Later EKS-drain,
  Provider-request, EBS, IAM, DNS-family, and load-balancer-family failures remain unlicensed.
- The EKS-checkpoint no-mutation read-back counterexample is closed code-locally. Recovery now
  re-observes the exact checkpoint pair before selecting its proof path: an exact current primary
  closes directly with no Authority submission, while backup-only recovery continues through the
  previously admitted restore operation and its independent read-back. Partial, unobservable,
  corrupt, and binding-mismatched observations remain refusals. Focused validation passes **11/11**
  at `/tmp/prodbox-sprint-6.5-checkpoint-no-mutation-readback-focused.log`,
  `sha256:7ee3a9656b58dd9a074d5b50bb10583f433a902dc5fbd43e1a8d22346e99d724`. Complete unit
  validation passes primary **4902/4902** plus auxiliaries **27/27**, **35/35**, and **37/37** at
  `/tmp/prodbox-sprint-6.5-checkpoint-no-mutation-readback-unit.log`,
  `sha256:bcb1a6094b12f67a47106ffd1539d9a5d81fbd3f70ff6d66bdc7415ed54b3d7a`. Canonical
  `prodbox dev check` passes with pinned formatting, HLint `No hints`, repository/generated-document
  policy, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-checkpoint-no-mutation-readback-dev-check.log`,
  `sha256:fb33b93eb0fd3459f725ff558c184a279332a46f3175eb9689419904ee009e11`. The synchronized
  executable is `sha256:c1b2df0688c4ccdba2ce62d262832a55facb84a9cee35eabab96d19c7b3cf754`.
  Run distinct live cycle `recovery-aws-eks-checkpoint-no-mutation-readback` next; the legacy public
  writer remains sole.
- Live `recovery-aws-eks-checkpoint-no-mutation-readback` exits **1** on 2026-09-09 but proves the
  checkpoint correction. The run builds local image
  `sha256:0aef7a375cee8baaa12c797a7907392e8c011464aa4ccf83800a9e81c197898e` in **1,127.7 s**,
  publishes Registry manifest
  `sha256:9d2a8a09c0f5b8120f32a67aca725a34e28d9f43d33b3832ba08033d9205ce31`, and imports OCI
  manifest `sha256:6d42fe5320abdb1b415bb55c90949d342503ac82168b6e8aa4b86fa515be74c6` in **92.3 s**;
  retention removes only the immediately superseded manifest/image. Recovery Establish, initial
  read-back, and final disposition succeed, as do EKS target observation, checkpoint-pair
  observation, restore, and mandatory checkpoint recovery read-back. The independent EKS
  drain-intent commit then refuses because authenticated transport maps Authority's exact 404
  `EksDrainIntentWireRecoveryMissing` to generic `EksDrainIntentClientRemoteRefused` instead of the
  client model's existing `EksDrainIntentClientRecoveryMissing`; this prevents the already-closed
  create-on-missing arm. Stable counterexample
  `CASCADE-QUALIFICATION-EKS-DRAIN-RECOVERY-MISSING-WIRE-2026-09-09` owns only recovery-action
  preservation of that exact missing response. Every other wire refusal, unavailable response,
  action, and HTTP-status mismatch remains non-absence. Durable run
  `cascade-qualification-recovery-aws-eks-checkpoint-no-mutation-readback` preserves primary
  `CleanupPrimarySucceeded` and graph digest
  `1774b488c41bfafb76118c5dc6b5b3aa0a3c482a097d35dc28a0b728677f85cd`. Evidence
  `.test-data/qualification/cascade-30a6a1f3a2fe0e3c9967f8c1.evidence` has governed digest
  `9699d51f595144fd37f850c82586f17ddea96a2bcbda0f7ca41e691820932d2c` and file SHA-256
  `9e661cc92d2dd361a2e623e2f246343b8dbbda96c40004259a96679c4a195e9c`. Transcript
  `/tmp/prodbox-sprint-6.5-checkpoint-no-mutation-readback-live-recovery-aws-eks-checkpoint-no-mutation-readback.log`
  is `sha256:18703249accdf10b81d0f98bc13202ad821733fe81bf017d9a7f656a52009499`. Parallel
  stack-reader Provider-request, EBS, IAM, DNS-family, and load-balancer-family failures remain
  unlicensed.
- The EKS drain-intent recovery-missing wire counterexample is closed code-locally. The
  authenticated transport preserves only the recovery action's canonical Authority
  `EksDrainIntentWireRecoveryMissing` response as the client model's typed recovery-missing value,
  which reaches the executor's existing create-on-missing arm. A distinct not-found refusal is
  regression-proven to remain `EksDrainIntentClientRemoteRefused`; unavailable responses, wrong
  actions, proof mismatches, and HTTP-status mismatches remain non-absence. Focused repository,
  endpoint, and authenticated-transport validation passes **16/16** at
  `/tmp/prodbox-sprint-6.5-eks-drain-recovery-missing-wire-focused.log`,
  `sha256:284b974ff8b23e810d66c234f829d954d3beac76e2dc47b4dbc9dcaf81ac856b`. Complete unit
  validation passes primary **4903/4903** plus auxiliaries **27/27**, **35/35**, and **37/37** at
  `/tmp/prodbox-sprint-6.5-eks-drain-recovery-missing-wire-unit.log`,
  `sha256:809c70477edf57d8760586e05041ff898b8529f86da4b878609c261dd2cb2f24`. Canonical
  `prodbox dev check` passes with pinned formatting, HLint `No hints`, repository/generated-document
  policy, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-eks-drain-recovery-missing-wire-dev-check.log`,
  `sha256:fc7b16e64e5076759c2c8117bbafaa5ecfbb591046a2abc6c427e8fe7a91a4ca`. The synchronized
  executable is `sha256:138c0bc74d789daa9f434882a8e0fe5e7f664a2b6506d880d9584e0c744c4767`.
  Run distinct live cycle `recovery-eks-drain-recovery-missing-wire` next; the legacy public writer
  remains sole.
- Live `recovery-eks-drain-recovery-missing-wire` exits **1** on 2026-09-09 but proves the exact
  drain transport correction: recovery-missing reaches the existing create-on-missing arm and its
  fresh Provider observation. The run builds local image
  `sha256:435dce10327dd4549112387549186bd23bf101686d52882b7ad18630324c5fd1` in **1,145.7 s**,
  publishes Registry manifest
  `sha256:a27e6c1bc8e5e624259e3fabcbef12ddbdf3986755fa924acc94425dfbd8e146`, and imports OCI
  manifest `sha256:c1b8309a4dbf590776a6e29b791e0b54c77f45e3512e81ca63a59c85b17fdb11` in **90.5 s**;
  retention removes only the immediately superseded manifest/image. Recovery Establish, both
  read-backs, final disposition, EKS target observation, checkpoint-pair observation, restore, and
  recovery read-back all succeed. Drain commit and parallel stack-reader, EBS, IAM, DNS-family,
  and load-balancer-family Provider calls then expose
  `ProviderWorkerResponseInvalid ControlPlaneRequestInvalid`. Read-only Provider Worker workload
  diagnostics show affected requests either complete authenticated ingress, intent admission,
  trust and clock revalidation, narrow-session and credential binding, capability execution,
  authority projection, and response encoding, or stop after socket ingress. The Provider client
  currently decodes every outer authenticated-runtime plaintext response as a role response, so
  the exact outer refusal is lost. Stable counterexample
  `CASCADE-QUALIFICATION-PROVIDER-WORKER-PLAIN-RESPONSE-DIAGNOSTIC-LOST-2026-09-10` owns only a
  closed value-free classification at that boundary; Provider execution and replay policy remain
  unchanged until the diagnostic names the refusal. Durable run
  `cascade-qualification-recovery-eks-drain-recovery-missing-wire` preserves primary
  `CleanupPrimarySucceeded` and graph digest
  `4a5f51d6ce51c74f7cf3d3f486f481d18db0037fbbfd2b590c4e9ab413c0e845`. Evidence
  `.test-data/qualification/cascade-d4a57708edbd0b6e5b2f4273.evidence` has governed digest
  `2ac00a2309c8dde3204f2c836c53e097f6a56272584294c42d69196e4d594f16` and file SHA-256
  `22c92f1b1d5e85eaeec0aead61cf6c17297d334a3302be0ba342db6cdc525fcb`. Transcript
  `/tmp/prodbox-sprint-6.5-eks-drain-recovery-missing-wire-live-recovery-eks-drain-recovery-missing-wire.log`
  is `sha256:14eb4d657f250c0955e85acdb75b60f2275181a9bfa75e89dcca2a839e096c2c`. This is not a
  qualification or activation witness; the legacy public writer remains sole.
- The Provider Worker plaintext-response diagnostic is closed code-locally. Canonical Provider
  response decoding remains first; only a failure crosses the authenticated-role interpreter's
  total exact status/body classifier. Each of its 21 static response pairs becomes a closed
  bodyless observation, while wrong or unknown plaintext remains a codec failure. The diagnostic
  changes no HTTP response, replay policy, retry, Provider execution, evidence, or cleanup
  decision. Focused Provider validation passes **27/27** at
  `/tmp/prodbox-sprint-6.5-provider-worker-plain-response-diagnostic-focused.log`,
  `sha256:742a0e323593ef719b14479a684412c4d1f4bd1a5c6c5ac0788181269e1b9f5d`. Complete unit
  validation passes primary **4904/4904** plus auxiliaries **27/27**, **35/35**, and **37/37** at
  `/tmp/prodbox-sprint-6.5-provider-worker-plain-response-diagnostic-unit.log`,
  `sha256:2546d42e39ecba425a3489204be8e022297a11c695e9743a6697aee2fa925c8d`. Canonical
  `prodbox dev check` passes with pinned formatting, HLint `No hints`, repository/generated-document
  policy, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-provider-worker-plain-response-diagnostic-dev-check.log`,
  `sha256:c2bf06997f86b829d54cce52a7be436aaf844457c28bbafedd521a9a22c3fefd`. The synchronized
  executable is `sha256:6474fd818d8cc92fe49b6ca73be5222557d1a9e58b524c4754ecf8821ae2de59`.
  Run distinct live cycle `recovery-provider-worker-plain-response-diagnostic` next; the legacy
  public writer remains sole.
- Live `recovery-provider-worker-plain-response-diagnostic` exits **1** on 2026-09-10 and closes
  `CASCADE-QUALIFICATION-PROVIDER-WORKER-PLAIN-RESPONSE-DIAGNOSTIC-LOST-2026-09-10`. The run builds
  local image `sha256:d4360640abd34fa62e52560bf650f7d4bfea87ad06bb0c363d52f7180a2e83e4` in
  **1,125.0 s**, publishes Registry manifest
  `sha256:2c1e62268f379585ec7a56a27959a2197f774f2244a42ab735282eeaf80b75a6`, and imports OCI
  manifest `sha256:a3088872e5a2b87ad8e75c0372a47f02c1eccc179382a7601cea4ac3c7ead502` in **98.1 s**;
  retention removes only the immediately superseded manifest/image. Recovery Establish, both
  read-backs, final disposition, EKS target and checkpoint-pair observation, checkpoint restore,
  and checkpoint recovery read-back all succeed. The drain commit and parallel Provider-backed
  nodes now preserve the exact outer refusal as
  `ProviderWorkerAuthenticatedRoleResponse (AuthenticatedRolePlainResponseKnown
  AuthenticatedRoleReplayCapacityExhausted)`. Stable counterexample
  `CASCADE-QUALIFICATION-PROVIDER-WORKER-REPLAY-ENVELOPE-UNDERSIZED-2026-09-10` owns the Provider
  role's generic capacity four: derive its complete qualification Provider request envelope plus
  one immediate unchanged retry, preserve every retained entry through the supported replay-codec
  widening, align the replay response maximum with the existing 64 KiB Provider client maximum,
  and prove the existing 12 MiB encoded ceiling. Durable run
  `cascade-qualification-recovery-provider-worker-plain-response-diagnostic` preserves primary
  `CleanupPrimarySucceeded` and graph digest
  `c0a16c37202088374a1b1f19a9c76928d92cedb04c59df50a3155841892af468`. Evidence
  `.test-data/qualification/cascade-fbd1df8f1616e32bd71a8117.evidence` has governed digest
  `4f297689214303fb651e05aa55de2bf6a223cc05c0affc2fb6df6ec98bce4c0b` and file SHA-256
  `feca5d27c7303592c11d2db5b9be39e2ecbfb625e8d37e6f9cd373211d72f181`. Transcript
  `/tmp/prodbox-sprint-6.5-provider-worker-plain-response-diagnostic-live-recovery-provider-worker-plain-response-diagnostic.log`
  is `sha256:5e186c2f0dca6d8b188fe57ac152ef6d512fcca9ddb4caa1d26a98bcf0fba077`. This is not a
  qualification or activation witness; the legacy public writer remains sole.
- Code-local closure for
  `CASCADE-QUALIFICATION-PROVIDER-WORKER-REPLAY-ENVELOPE-UNDERSIZED-2026-09-10` derives one exact
  complete qualification attempt as `1 + 6 * 4 + 3 + 7 + 5 = 40` Provider Worker requests: one
  operational AWS-scope proof; four requests each for six Provider-mutated non-EKS registered
  families; three Provider observations for the Kubernetes-owned DNS01 family; seven EKS
  observation/drain/destroy/read-back requests; and five terminal-audit queries. The role retains
  two complete attempts at capacity **80**, uses its already-enforced 64 KiB client response limit
  at the server replay boundary, and keeps the 12 MiB encoded ceiling. Canonical v2 through v11
  widening into v12 preserves every retained entry. The focused authenticated-transport suite
  passes **39/39** at
  `/tmp/prodbox-sprint-6.5-provider-worker-replay-envelope-focused.log`,
  `sha256:aac6f7ef2374ed415fdd4d54e5327b1e14fc26b0d67f157ec2b0d7fcb11e35ef`. Exact-state full unit
  passes primary **4,904/4,904** and auxiliaries **27/27**, **35/35**, and **39/39** at
  `/tmp/prodbox-sprint-6.5-provider-worker-replay-envelope-unit.log`,
  `sha256:977ddc8725a311b57d6559aaa6be8ab389c7f502f78538a6cbabbb57fce34def`. Canonical `prodbox dev
  check` passes at `/tmp/prodbox-sprint-6.5-provider-worker-replay-envelope-dev-check.log`,
  `sha256:310e1d99ae3dffc4fb806eb7138b58bddf9301b78fdb777e411b951c8fb030e9`; the synchronized
  executable is exact at
  `sha256:aa601b56945f3ad3bc73b08c549b70774f1d9f0ee31ba95e25eb9ae55377b9cc`. Run distinct live cycle
  `recovery-provider-worker-replay-envelope` next; the legacy public writer remains sole.
- Live `recovery-provider-worker-replay-envelope` reaches the Provider Worker rollout on 2026-09-10
  but is interrupted before the redundant 30-minute Helm timeout after the new Pod remains Running
  with zero restarts and not Ready for more than seven minutes; direct read-only probes return
  liveness **200** and readiness **503**. It builds local image
  `sha256:f49c57f3a0f03e303dcecbd0402f5ab8e1e365dc33d19f014b2603456dbe6c07` in **1,119.7 s**,
  publishes Registry manifest
  `sha256:12d5e52e648e290337aa87b77afe29489bd5429afcfc6b2a645f49117bf00f5b`, and imports OCI manifest
  `sha256:d1a5d5887133affb3969b8d32217642c0123000ada6ddecdd9555ad88234ab49` in **100.4 s**; retention
  removes only the immediately superseded manifest/image. Stable counterexample
  `CASCADE-QUALIFICATION-PROVIDER-WORKER-REPLAY-LIMIT-MIGRATION-UNADMITTED-2026-09-10` owns the
  deterministic startup mismatch: current codec v12 requires exact capacity, while every admitted
  prior version requires exact response maximum, so retained capacity-four/2 MiB Provider state
  cannot enter capacity-80/64 KiB runtime even when every entry fits the narrower bound. Advance
  the codec to v13; admit canonical v2-through-v12 only for capacity widening plus response-bound
  narrowing whose entries all validate under the new limit; preserve every entry and keep clock
  equality, shrink, response widening, corruption, and oversize-entry cases fail-closed. The run
  emits no candidate governed evidence. Transcript
  `/tmp/prodbox-sprint-6.5-provider-worker-replay-envelope-live-recovery-provider-worker-replay-envelope.log`
  is `sha256:1f439943b13caa429284ddc4faf7f5cd3dd2201ccc7ac7502f6be7cbe86e550b`. Run distinct live cycle
  `recovery-provider-worker-replay-envelope-v13` after code-local closure; the legacy public writer
  remains sole.

- The recovery-enabled live `pre-1` builds local image
  `sha256:be8e1b8ffe9c0467b2685f7620c7da2ba09c9ba083cc69208277b49be1cc6d0d` in
  **1,119.1 s**, publishes Registry manifest
  `sha256:2d4ab5aad4a929659faf1fd6ea0e4bd589b1db4942e78dc278bdf8c9907bd741`, and imports OCI
  manifest `sha256:6668901dcb20ff08cc81a77e83352c1584032eb07be06441be160ff50633283d`
  in **90.4 s**. Retention removes only the immediately superseded manifest/image. The new Target
  Agent then remains Running with zero restarts but not Ready for the complete ten-minute rollout;
  its exact protected cause is
  `readiness/dependency-unavailable/request-replay-projection`, and Helm's failed-release cleanup
  proves the release absent. The transcript is
  `/tmp/prodbox-sprint-6.5-tls-legacy-recovery-live-pre-1.log` at
  `sha256:73c3b994d8ce20abca5807504f61c3a9d4ed7a88b6728a9380e2367a54ba42bd`; the read-only
  protected-log reproducer is
  `/tmp/prodbox-sprint-6.5-tls-legacy-recovery-target-readiness-sampler-2.log` at
  `sha256:79486bfc533e40b4b52e8b25341c8456edd87e065f2da533496fe0bcafe7c40f`.
  Stable counterexample `TARGET-AGENT-REPLAY-V9-CAPACITY-DRIFT-2026-09-08` owns the exact
  retained-codec boundary; TLS recovery and candidate execution are not reached.
- That counterexample is closed code-locally without clearing retained evidence or weakening a
  limit. The deployed projection is canonical request-replay v9 at capacity 58, while the new
  complete-attempt envelope requires 64. Codec v9 required exact limits, so startup correctly
  refused the widened runtime. Codec v10 now admits canonical nonempty v2–v9 projections only when
  response-size and clock-skew limits are identical and prior capacity is no greater than the new
  compiled capacity; every entry is preserved and rewritten as v10 only on the next CAS. Capacity
  shrink, response/skew drift, malformed/noncanonical bytes, duplicate keys, invalid entries, and
  evidence clearing remain refusals. The authenticated-transport regression passes **36/36** at
  `/tmp/prodbox-sprint-6.5-target-replay-v9-widen-focused.log`,
  `sha256:1058f0200eaebf104da1df1500c40b4b370737f42b02a430214fed5efd0c22d4`;
  canonical unit validation passes **4,880 + 27 + 35 + 36** at
  `/tmp/prodbox-sprint-6.5-target-replay-v9-widen-unit.log`,
  `sha256:d044fdfdbb30b095dbb0c2ca11c7db7ed734804e4378b7de41733ef854995cb1`.
  Documentation-inclusive `prodbox dev check` passes at
  `/tmp/prodbox-sprint-6.5-target-replay-v9-widen-dev-check.log`,
  `sha256:823f917f14d3e63e56dd225cc12896e31bec14eecc0dafcec280b16dfc66e7fc`; the synchronized
  executable is `sha256:479d9a01ea84459deba3ee9f3e291dcc5ea0247d03cc1027d49e6b654e8cd93b`.
  Exact live `pre-1` is next. No candidate qualification artifact, activation witness, or exact
  cleanup proof exists, and the legacy public writer remains sole.
- The corrected live rerun proves that barrier and completes home reconcile on local image
  `sha256:7d8f4318...` and registry manifest `sha256:20488c96...`. It then stops before candidate
  execution at AWS IAM harness setup: the executable-sibling Tier-0 config is still the unauthored
  portable skeleton, so `aws_substrate.subzone_name` is empty. Stable counterexample
  `AWS-QUALIFICATION-TIER0-UNAUTHORED-2026-08-31` names that prerequisite refusal. Operational
  credentials are preserved because exact terminal cleanup was not proved; no qualification
  artifact or activation witness was produced.
- Root cause is closed in the generator rather than by hand-authoring its generated artifact.
  Sprint `7.37` added `aws_substrate.profile` and the EKS topology consumer but the automation
  fixture/generator still carried only the earlier field set. Haskell-owned `TestSecrets` now adds
  the explicit AWS subzone, narrowed profile, and EKS desired size. AWS runs generate the exact EKS
  topology; home runs retain RKE2; `harnessGeneratedConfig` writes the complete AWS section. The
  schema is regenerated from Haskell, the ignored operator fixture restores the historically
  deployed `aws.test.resolvefintech.com` resource/network envelope and current observed ingress
  `/32`, and focused generation, refusal, preservation, and schema round-trip tests pass. The full
  primary suite passes **4760/4760**, installed `clean-room-handoff` passes, and canonical `prodbox
  dev check` passes. The generated-artifact gate rejected and caused removal of an intermediate
  direct Tier-0 edit. The first exact `pre-1` retry stops before mutation at the preservation
  classifier. An exact-canonical-default guard passes its focused regression, but the next retry
  proves the on-disk input is the harness-owned prior home-run config under
  `.test-data/legacy-aggregate`, not the canonical skeleton: its older schema has populated home
  fields, no AWS subzone/profile, and an RKE2 topology. Stable counterexample
  `AWS-HARNESS-OWNED-PRIOR-CONFIG-PRESERVATION-2026-09-01` is closed by refreshing only a config
  under the exact harness-owned storage root when a required authored field is absent or its
  topology does not match the requested substrate. An otherwise identical operator-owned path
  still refuses. Both focused guards pass **1/1**, the full primary suite passes **4762/4762**,
  installed `clean-room-handoff` passes, and canonical `prodbox dev check` passes. Rerun `pre-1` so
  the harness generates and admits the authored proposal before AWS IAM setup. That rerun does so,
  live-proves the Authority Backup barrier again, and completes retained-home reconcile on local
  image `sha256:7b3f87f4...`, registry manifest `sha256:c0060e43...`, and reported OCI import
  manifest `sha256:129f4e4e...`. It then stops before candidate execution in IAM setup: cleanup of
  the prior configured operational identity deletes only the current fixed inline-policy name
  before `iam delete-user`, so AWS returns `DeleteConflict` while other policy dependencies remain.
  Stable counterexample `AWS-OPERATIONAL-USER-POLICY-DEPENDENCY-ORDER-2026-09-01` is closed by
  enumerating/deleting every inline policy and enumerating/detaching every attached managed policy
  before user deletion for both fixed and associated operational identities. The focused regression
  passes **1/1**, the full primary suite passes **4763/4763**, installed `clean-room-handoff`
  passes, and canonical `prodbox dev check` passes. Rerun `pre-1`; no qualification artifact or
  activation witness exists.
- That exact retry builds local image
  `sha256:1d7e0f9f26b364c7a3c7a1d6b755177172a23c35ef772f523bbe3d3d1205b1d5`, registry manifest
  `sha256:6be52e65e013068ab7c855bf5644c8bd3b0c7e3411b0f2b7a5abc93d2dfd3d77`, and OCI import
  manifest `sha256:5e9f85025351d961b893783b1f628e3aa5b468f9cf629476ef656990f6d7e35b`. Provider Worker then
  remains zero-restart but returns only HTTP 503 from `/readyz` until Helm reaches the Deployment
  progress deadline; failed-release cleanup uninstalls it and verifies absence. The earlier partial
  legacy IAM cleanup deleted the configured user's keys before its policy-order refusal. Full
  pre-IAM reconcile therefore waits for Provider STS readiness that only the later IAM refresh can
  repair. Stable counterexample
  `AWS-HARNESS-PRE-IAM-PROVIDER-READINESS-CYCLE-2026-09-01` names the cycle; IAM setup and candidate
  execution are not reached and no artifact or activation witness exists.
- The correction is landed for code-local validation. The harness projects the ordinary reconcile
  graph through bootstrap and the retained Authority/config transition only, excluding Provider
  Worker and every other steady component. It then observes only the Lifecycle-provider Target
  metadata and drives the exact install-or-rotate program through the authenticated, attested
  Credential Provisioner with a stable per-cycle operation identity; a retained operation is
  recovered byte-for-byte after response loss. Public `cluster reconcile` remains full and keeps
  Provider deep readiness strict. Once the qualification candidate proves its own typed credential
  revocation, the harness does not invoke the legacy IAM teardown as a second writer. The focused
  graph/operation group passes **14/14**, the full primary suite passes **4764/4764**, installed
  `clean-room-handoff` passes, and canonical `prodbox dev check` passes. The gate-built executable
  is exact at `sha256:3eb8d96a676a1de0f91c4598026d01594a36567280bd44b0beae8029ba7febff`; live `pre-1`
  on the final documentation-inclusive revision is next.
- That live retry builds local runtime image
  `sha256:859e6e5cadef767428139ca327a4c9e772e4d5949d5c03317852526c8310ceba`, publishes registry
  manifest `sha256:510b0d8ffc76203f2fe714cfd5a39714d6d1ed5cf1210f3c49201ee34bf431a6`, and imports OCI
  manifest `sha256:4550a097c65450212304388b81d3a42ebab75cb44d7eec4f670b1b7142a72c93`. The bootstrap floor
  completes and the authenticated Credential Provisioner rotates the Lifecycle-provider Target to
  Generation 2, closing the earlier readiness cycle in live execution. The following managed ACME
  EAB Authority ingress fails closed with `ExternalMaterialWorkflowJobFailed
  (CredentialProvisionerJobCreateFailed "Job create was not recovered and stable absence was
  proven")`. Candidate execution is not reached, operational credentials are preserved, and no
  artifact or activation witness exists. Stable counterexample
  `AWS-HARNESS-ACME-EAB-JOB-CREATE-ABSENT-2026-09-01` owns this distinct post-rotation Job-create
  boundary. Diagnose its exact typed request/identity and Kubernetes observation path before any
  implementation change; the legacy public writer remains sole. The exact Kubernetes server-side
  dry run reproduces the cause: the `eab-` plus 64-hex permit ID is 68 bytes, while the renderer put
  it in both Job and Pod labels whose maximum value is 63 bytes. The same inspection proves the
  attestation reads the exact permit from the `prodbox.io/permit-id` annotation, which the renderer
  omitted. The counterexample is closed code-locally by removing the full permit from labels and
  carrying it in the secret-free exact Job and Pod annotations. The focused regression passes
  **1/1**, and the corrected long-permit manifest passes server-side admission under the exact
  test-harness impersonation. The full primary suite passes **4765/4765** in 89.14 seconds and
  canonical `prodbox dev check` passes with HLint `No hints` and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:9baf5bffba04fd21dff30d94e568d8d2e0378338f62b62407aee1597f1f5721c`; rerun live `pre-1`
  on this final documentation-inclusive revision.
- That retry builds local image
  `sha256:30940c3767222de19303e5f737f428900013153b7ceffc877b5d0f4bfd1a1267`, publishes registry
  manifest `sha256:9416b5aecbd58ee976dfe7f9b1328c3e591acda135b17650fca0d9f84f0b4b5f`, and imports OCI
  manifest `sha256:4bf91af0dca3951dd71847c6464425f5fb8e8b15e1a2743278118865c0c601e0`. It reaches the
  retained Lifecycle-provider credential before ACME EAB ingress, but the reused `pre-1` operation
  carries its original expired absolute deadline and refuses at
  `AwsAdminCoordinatorPrepareFailed (AwsAdminProvisionerClientUnavailable
  "prepared-target/deadline-expired")`. Stable counterexample
  `AWS-HARNESS-RETAINED-CREDENTIAL-DEADLINE-REPLAY-2026-09-01` owns this retry boundary. The EAB
  job and candidate are not entered, credentials are preserved, and no artifact or witness exists.
  The protected Authority diagnostic confirms `aws-admin/prepare authority-phase=completed`: the
  endpoint was sending an exact completed replay through deadline-gated prepared-target
  publication before the coordinator could recover its authenticated receipt and prove Job
  absence. The counterexample is closed code-locally by returning the retained prepared challenge
  only for a byte-for-byte completed intent; divergent completed requests remain refused, and the
  existing coordinator retains exact receipt recovery plus UID-bound Job/Pod absence ownership.
  The focused endpoint regression passes **1/1** and proves completed replay reads neither
  Authority time nor the prepared-target effect; the full primary suite passes **4766/4766** in
  88.35 seconds. Canonical `prodbox dev check` passes with HLint `No hints` and warning-clean
  all-target compilation. The synchronized executable is exact at
  `sha256:c8ee0dc4cb36be814dab2f266c83f2396846f02ee61125b98f7cfb4a849edcae`; rerun live `pre-1`
  on this documentation-inclusive revision.
- That retry builds local image
  `sha256:06b9c1e4f606b2b157da4928d7c4fd62208f0ddf31a7075e6ba4a85a9612af5d`, publishes registry
  manifest `sha256:f98865f20657ef236620f62bc8ee3e873afeb06f1103924f6968e94a9283d4e5`, and imports OCI
  manifest `sha256:3c47184277e18701194c383e9c02d366c2ba43935454aa0c1c7c50a1103078c5`. The exact completed
  Lifecycle-provider replay returns Generation 2, live-closing
  `AWS-HARNESS-RETAINED-CREDENTIAL-DEADLINE-REPLAY-2026-09-01`. Managed ACME EAB ingress then
  fails closed at `ExternalMaterialWorkflowCleanupFailed CredentialProvisionerJobStillPresent`;
  candidate execution is not reached, credentials are preserved, and no artifact or witness
  exists. Stable counterexample
  `AWS-HARNESS-ACME-EAB-JOB-CLEANUP-STILL-PRESENT-2026-09-01` owns this post-execution cleanup
  boundary. Diagnose the exact retained Job/Pod identity and deletion/absence observations before
  changing implementation; the legacy public writer remains sole. Read-only inspection finds the
  same exact-UID Job and owned Pod still `Running` with no deletion timestamp, while authorization
  checks prove the harness owns create/get/list/delete on that namespace. The delete boundary never
  spawned `kubectl`: `deleteLimits` admitted only one input byte although the mandatory
  UID-preconditioned `DeleteOptions` JSON is larger, so bounded-subprocess admission rejected its
  own payload and the later absence probe correctly reported presence. Close this code-locally with
  one small explicit delete-payload ceiling and a regression that proves the canonical payload is
  both nonempty and admitted before rerunning code-local gates. The 4 KiB bounded-input fix passes
  its focused regression **1/1**, and the full primary suite passes **4766/4766** in 88.31 seconds.
  Canonical `prodbox dev check` passes with HLint `No hints` and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:7fd102a94adb10f975b0b8c9f3bafe673fd6d704a8840e6946ceb84aebcdf245`; rerun live `pre-1`
  to recover the retained exact Job and continue qualification on this documentation-inclusive
  revision.
- That recovery retry builds local image
  `sha256:afff39c1659ee27a92ad77d62cb9410ea89bcdf928c5c0c175d19bb804a7f26e`, publishes registry
  manifest `sha256:f1ef4d39e6ac0d6a8b265eabf1f75879b5fb5f1b7b09eeac69e19909801e5408`, and imports OCI
  manifest `sha256:52e9d05f23cd6c12cc1a1adfa1161477f3827586c8373e17c5dd8b52da0203dd`. It no longer reports
  `CredentialProvisionerJobStillPresent`; recovery instead observes the retained EAB Job after its
  owned Pod has disappeared and fails closed at `ExternalMaterialWorkflowJobFailed
  (CredentialProvisionerJobObservationFailed "Job has no Pod")`. Candidate execution is not
  reached, credentials are preserved, and no artifact or witness exists. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RECOVERY-JOB-WITHOUT-POD-2026-09-01` owns this distinct retained-job
  topology. Inspect exact post-run Job/Pod absence and the committed Authority phase before
  changing recovery semantics; the legacy public writer remains sole. Post-run observation proves
  both the exact Job and every owned Pod absent; Kubernetes events show the Job controller removed
  the Pod at the original active deadline, and the corrected UID-preconditioned cleanup then
  removed the Job. This live-closes
  `AWS-HARNESS-ACME-EAB-JOB-CLEANUP-STILL-PRESENT-2026-09-01`. Re-enter the same supported cycle on
  the unchanged executable to expose the now-absent retained Authority branch and its exact
  deadline disposition before changing intent or recovery semantics.
- That unchanged cached-image rerun retains local image
  `sha256:afff39c1659ee27a92ad77d62cb9410ea89bcdf928c5c0c175d19bb804a7f26e` and registry manifest
  `sha256:f1ef4d39e6ac0d6a8b265eabf1f75879b5fb5f1b7b09eeac69e19909801e5408`. The nonterminal
  Authority operation creates a successor Job after stable absence, but its retained challenge is
  bound to the prior registry manifest while the stable repository tag now resolves to the current
  manifest; Pod attestation fails closed at `ExternalMaterialWorkflowJobFailed
  (CredentialProvisionerJobObservationFailed "\"container image digest mismatch\"")`. Candidate
  execution is not reached, credentials are preserved, and no artifact or witness exists. Stable
  counterexample `AWS-HARNESS-ACME-EAB-CONTAINER-IMAGE-DIGEST-MISMATCH-2026-09-01` owns this exact
  retained-intent/mutable-tag conflict. Prove terminal Job/Pod absence, then make the Job pull the
  intent-bound immutable manifest rather than weakening attestation or rebinding retained intent.
  Post-run observation again proves exact Job/Pod absence, and read-only registry inspection proves
  both the retained and current manifests remain addressable by digest. Close this code-locally by
  rendering the supplied repository/tag with the intent-owned `@sha256:` manifest selector and by
  regressing that no mutable-only image reference reaches the Pod spec. The implementation uses one
  opaque `CredentialProvisionerImagePullReference` constructor to validate repository shape,
  canonical manifest identity, and total length before the Kubernetes renderer can obtain text; the
  Pod manifest never assembles a digest reference itself. The focused renderer/compiled-ownership
  regressions pass **2/2**, and the full primary suite passes **4766/4766** in 89.66 seconds.
  Canonical `prodbox dev check` passes with HLint `No hints` and warning-clean all-target
  compilation. The synchronized executable is exact at
  `sha256:89957264fee4467ff477b7193293c471f4c5a9603f03eec193d4a04f83f31384`; rerun live `pre-1`
  on this documentation-inclusive revision.
- That retry builds local image
  `sha256:e53123ffa08da63895ab553a567e62a3d5470c88d41caf06a676c1fe7e00b686`, publishes registry
  manifest `sha256:e2ff4f9443695ed2e4a55dd5c172ac86a71cbe8b1e65055bc0cec417327ac512`, and imports OCI
  manifest `sha256:a823ff67bb97019a4bbcf9e364391074edd3753708e94639f3ddc5da06d1ca10`. The immutable
  intent-bound image pull succeeds and live-closes
  `AWS-HARNESS-ACME-EAB-CONTAINER-IMAGE-DIGEST-MISMATCH-2026-09-01`; attestation then rejects the
  retained operation's original expired absolute deadline at `ExternalMaterialWorkflowJobFailed
  (CredentialProvisionerJobAttestationFailed "CredentialProvisionerDeadlineExpired")`. Candidate
  execution is not reached, operational credentials are preserved, and no qualification artifact
  or activation witness exists. Stable counterexample
  `AWS-HARNESS-ACME-EAB-RETAINED-DEADLINE-EXPIRED-2026-09-01` owns this exact retained-intent
  deadline boundary. Prove terminal Job/Pod absence and inspect the nonterminal Authority phase
  before adding any renewal transition; the legacy public writer remains sole.
- Post-run observation proves the exact Job and every owned Pod absent. Kubernetes events prove the
  intent-bound `sha256:510b0d8ffc76203f2fe714cfd5a39714d6d1ed5cf1210f3c49201ee34bf431a6`
  manifest was pulled and the worker started before UID cleanup. The retained phase is exactly
  `ExternalMaterialIngressIntentCommitted`: the prior mutable-tag attempt failed before Authority
  authorization, and this run reached the first authorization against the same immutable intent.
  Close the counterexample code-locally with an exact prepared-only renewal transition: old
  deadline expired at Authority time, replacement deadline still active and strictly later, and
  the operator request plus permit binding byte-for-byte unchanged; image and active deadline may
  advance. Every attested, permitted, completed, binding-drifted, or active-deadline state remains
  refused. The current-observation selector requests that renewal only for the same expired
  intent-committed operation and otherwise retains exact replay/next-generation behavior.
- The exact prepared-only renewal and selector regressions pass in the focused lifecycle group
  **16/16**, and the full primary suite passes **4767/4767** in 89.26 seconds. Canonical
  `prodbox dev check` passes with HLint `No hints` and warning-clean all-target compilation. The
  synchronized executable is exact at
  `sha256:302b1374df9fb32caae2784e538ffb81fcadfcba811d9763825d9c331171f126`; rerun live `pre-1`
  on this documentation-inclusive revision.
- That retry builds local image
  `sha256:a7d15ce52ce799742cc2e8035b11824d7d8bd0f1cab0a8798641d5dc64f5a7b9`, publishes registry
  manifest `sha256:7d75458066551352e068fd6543da807668cc48bdf987154b99a9a43fefd33456`, and imports OCI
  manifest `sha256:0153cd66c0b8864350a7b9b3bb11a117ea539503618dff7821e3a5d5b586c7ef`. Prepared-only
  renewal succeeds and live-closes
  `AWS-HARNESS-ACME-EAB-RETAINED-DEADLINE-EXPIRED-2026-09-01`; the renewed worker then fails at
  `ExternalMaterialWorkflowJobFailed (CredentialProvisionerJobReceiptInvalid
  "ExternalMaterialTargetReceiptDecodeFailed")`. Candidate execution is not reached, operational
  credentials are preserved, and no qualification artifact or activation witness exists. Stable
  counterexample `AWS-HARNESS-ACME-EAB-RENEWED-RECEIPT-DECODE-FAILED-2026-09-01` owns this exact
  post-worker receipt-codec boundary. Prove terminal Job/Pod absence and distinguish attach stdout
  framing from worker receipt encoding before changing either side; the legacy public writer
  remains sole.
- Post-run observation proves the exact Job and every owned Pod absent. Kubernetes events prove the
  renewed worker pulled the exact current registry manifest, ran for 13 seconds, and was then
  UID-cleaned. The worker writes canonical binary receipt bytes, and the controller requires those
  bytes byte-for-byte; the `kubectl attach` subprocess omitted `--quiet`, whose documented contract
  is “only print output from the remote session,” so the transport did not guarantee an
  uncontaminated binary stdout stream. Close this code-locally by binding `--quiet` in the sole
  attach constructor and regressing its exact argv. Do not weaken canonical receipt decoding or
  treat the line-oriented Pod log fallback as the primary binary transport.
- The exact attach-argv regression passes in the focused lifecycle group **17/17**, and the full
  primary suite passes **4768/4768** in 86.07 seconds. Canonical `prodbox dev check` passes with
  HLint `No hints` and warning-clean all-target compilation. The synchronized executable is exact
  at `sha256:e0e539b964277f9a6ad06fc322a01f726a547f1af1a2284c2346319d4c63b343`; rerun live `pre-1`
  on this documentation-inclusive revision.
- That retry builds local image
  `sha256:9f67e270f0125245ca361544c699e7e0d046454ffcd2cdb6f19e12367b38f26a`, publishes registry
  manifest `sha256:b88adf31863ac50d7ccb9e07ff108008514532bcd33e99cd0c1a54841cab79ef`, and imports OCI
  manifest `sha256:b40ab9cedc5e852ce72c6a09f8c6b0305114b3ceb9677d6bbcde5affc2082a1a`. The retained
  Authority phase is already beyond intent after the prior worker effect and its Job is absent, so
  the corrected attach is not re-entered; recovery fails closed at
  `ExternalMaterialWorkflowCommittedJobLost`. Candidate execution is not reached, operational
  credentials are preserved, and no qualification artifact or activation witness exists. Stable
  counterexample `AWS-HARNESS-ACME-EAB-COMMITTED-JOB-LOST-2026-09-01` owns this exact
  committed-phase plus absent-Job topology. Prove exact Job/Pod absence and the retained
  phase/permit binding before adding recovery;
  `AWS-HARNESS-ACME-EAB-RENEWED-RECEIPT-DECODE-FAILED-2026-09-01` remains code-locally corrected
  but not yet live-closed, and the legacy public writer remains sole.
- Read-only postflight proves the credential-provisioner namespace has no Job or Pod. Source
  closure makes the retained phase exact: the worker could receive stdin only after Authority
  attestation and durable permit-outbox commit, and the prior failure occurred while decoding the
  worker's post-effect receipt, so the retained state is `ExternalMaterialIngressPermitCommitted`.
  The effect boundary is already receipt-recoverable: retained-home custody records an opaque
  generation, commitment, ciphertext digest, and Vault read-back version, and an exact replay
  returns that same source without resealing or reminting. Close this counterexample by letting the
  Authority ask the authenticated home Target Agent for that schema-closed,
  permit/generation-bound source observation, reconstruct the existing
  `ExternalMaterialTargetReceipt`, and CAS-read-back the ordinary completion transition before
  returning the prepared replay. Missing, mismatched, corrupt, or unobservable custody remains a
  closed refusal; no successor Job, caller-asserted absence, direct Authority Vault access, or
  weakened receipt decoder is licensed.
- That recovery is now landed. The authenticated Target Agent observation returns only the exact
  schema, permit-operation, generation, opaque receipt reference, opaque commitment, ciphertext
  digest, and Vault read-back version already held by retained custody. Lifecycle Authority
  reconstructs the ordinary receipt, validates it through the existing commit transition, and
  CAS-reads back completion; any missing or divergent observation remains unavailable. The focused
  external-material lifecycle group passes **18/18**, including the exact expired
  `PermitCommitted`/absent-Job replay; the full primary suite passes **4769/4769** in 85.93 seconds,
  and canonical `prodbox dev check` passes with pinned formatting, HLint `No hints`, and
  warning-clean all-target compilation. The synchronized executable is exact at
  `sha256:17cc83074644d1767d070f23db643b7d59cb688eb96377aadba17efe085cc0bc`; rerun live `pre-1`
  on this documentation-inclusive revision. The legacy public writer remains sole and no
  qualification artifact or activation witness exists yet.
- Code-local closure for
  `CASCADE-QUALIFICATION-PROVIDER-WORKER-REPLAY-LIMIT-MIGRATION-UNADMITTED-2026-09-10` advances the
  retained request-replay codec to **v13** and admits canonical **v2 through v12** state under one
  exact migration rule: stored capacity no greater than the compiled capacity, stored response
  maximum no smaller than the compiled maximum, exact clock-skew equality, and every retained
  response revalidated against the new maximum before the projection is accepted. Current-version
  state still requires exact capacity and exact response maximum, so the widening is legacy-only.
  Capacity shrink, response widening, skew drift, unsupported versions, duplicate keys, malformed
  or noncanonical bytes, and an oversized retained response all remain closed refusals, and every
  admitted entry is preserved and rewritten as v13 only on the next CAS. This lets the retained
  capacity-four/2 MiB Provider Worker projection enter the capacity-80/64 KiB runtime that Sprint
  `6.5`'s complete-attempt envelope requires. The focused authenticated-transport suite passes
  **39/39** at `/tmp/prodbox-sprint-6.5-provider-worker-replay-v13-focused.log`,
  `sha256:7af1c1842d8ee14876ce3a110c72b06838720ad2d8922fdcdf56fbce52528e3b`, including the exact
  v2-through-v12 widening case, the oversized-retained-response refusal, and the unsupported-version
  refusal. Exact-state full unit passes primary **4,904/4,904** and auxiliaries **27/27**,
  **35/35**, and **39/39** at `/tmp/prodbox-sprint-6.5-provider-worker-replay-v13-unit.log`,
  `sha256:56eba521581b5e232c293e35cfe1576e9758088b30c0a89fd9f6bc1ee386c2f7`. Canonical `prodbox dev
  check` exits **0** with pinned Fourmolu, HLint `No hints`, generated-artifact and documentation
  checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-provider-worker-replay-v13-dev-check.log`,
  `sha256:853c1b518d48c807973e43c0cad22fda263fcdd5f14b526f0cab7791525ffb2a`; the synchronized
  executable is exact at
  `sha256:52c9ba0343ee19f3d4fefc4f3438123fcef7eae856419f5db03184fbe0e5613c`. Run distinct live cycle
  `recovery-provider-worker-replay-envelope-v13` next; the legacy public writer remains sole and no
  qualification artifact or activation witness exists.
- Live `recovery-provider-worker-replay-envelope-v13` runs **2026-09-10 16:25:47–17:28:58 EDT** and
  live-closes `CASCADE-QUALIFICATION-PROVIDER-WORKER-REPLAY-LIMIT-MIGRATION-UNADMITTED-2026-09-10`.
  It builds local image
  `sha256:bfc3004b4b0872470ad23bcfd199b19abeb65cdb44a374261d4f18f6f0e0efe2` in **1,134.5 s**,
  publishes Registry manifest
  `sha256:1c3cfd0b398e622a944ae35b85112db44153685413c6a284cc0af13e256c46af`, and imports OCI manifest
  `sha256:6fd48a0a257579bab836764991a57e478b4f3aa9df74e070a584ec0daa49851e` in **95.3 s**; retention
  removes only the immediately superseded Registry manifest `sha256:12d5e52e...` and local image
  `sha256:f49c57f3...`. The v13 codec admits the retained capacity-four/2 MiB Provider projection
  into the capacity-80/64 KiB runtime: Provider Worker becomes **1/1 Ready with zero restarts**,
  and the run reaches Phase 2 candidate dispatch for the first time on this envelope. The candidate
  emits governed evidence
  `.test-data/qualification/cascade-c8cf66cc7cf766aa7ae8b52f.evidence` with governed digest
  `1d475bcf4c34b0a06b7c54bfc56358e99976b610c9957479672e60ec582179e0` and file SHA-256
  `29805a3f32e874666dfec6b468c71fe93afec79bdbf36f45b8e6a90fc2132bbb`, under run
  `cascade-qualification-recovery-provider-worker-replay-envelope-v13`, graph digest
  `f206b7ca054f9f11741afd31fa9d78937368b29c58603eb75a0e671675fb5f52`, and primary outcome
  `CleanupPrimarySucceeded`. The recovery-plane trio, the per-run test EBS family, the EKS load
  balancer controller family, the validation hosted zone, and the `aws-eks` observe, checkpoint-pair
  observe, checkpoint restore, checkpoint-recovery read-back, and stack-reader commit all succeed.
  The run nevertheless exits **1** at `cascade qualification did not reach exact terminal success`,
  preserves operational credentials, and produces no qualification or activation witness; the
  legacy public writer remains sole. The transcript is
  `/tmp/prodbox-sprint-6.5-provider-worker-replay-v13-live-recovery-provider-worker-replay-envelope-v13.log`
  at `sha256:81580fb2a1d5680858294ce077da0580e5eabcdf42e0c0528cc02bde8462f4c6`.
- That run registers two stable counterexamples on distinct branches, both proven from the exact
  node states in the same report.
  `CASCADE-QUALIFICATION-AWS-STACK-READER-SCOPE-DNS-ZONE-ERASED-2026-09-10` owns the branch that
  blocks the complete cascade tail: `lifecycle/target/aws-eks/commit-aws-stack-reader-bundle`
  succeeds and `lifecycle/target/aws-eks/read-back-aws-stack-reader-bundle` then refuses with
  `AwsStackReaderIdentityMismatch` between two identities that share submission key, run id, graph
  digest, operation id, registered key, coordinate digest, and every other scope field, and differ
  only in `internalEvidenceAwsDnsZone` — `Just (HostedZoneId "Z00231272QFGWVE1AJI2G")` expected
  against `Nothing` stored. Because `reconcile-absent`, `read-back-absent`,
  `retire-checkpoint-pair`, `read-back-checkpoint-retirement`, `audit-escapes`,
  `commit-pre-uninstall-report`, `uninstall-local`, and `commit-completion` are each transitively
  blocked on that read-back, no local uninstall or completion receipt is reachable.
  `CASCADE-QUALIFICATION-PROVIDER-EVIDENCE-REFUSAL-UNDIAGNOSABLE-2026-09-10` owns the drain branch:
  `lifecycle/target/aws-eks/commit-eks-drain-intent` refuses at
  `EksDrainCommitSelectionAccessUnobservable` carrying
  `AuthorityProviderRemoteRefused 503 "ProviderWorkerRemoteRefused 503
  \"ProviderIntentExecutionEvidenceInvalid \\\"provider evidence is invalid\\\"\""`, and that single
  closed text cannot say whether the observation was empty, over the character bound, or
  control-bearing, so the 503 carries no attributable cause. The three dependent drain nodes then
  report the derived `EksDrainIntentClientRecoveryMissing`. Four further node failures are recorded
  but deliberately **unattributed** pending an attributable cause: the `aws-eks-iam-role-family`,
  `aws-eks-subzone`, and `dns-aws-dns01-challenge-records` observations report only
  `registered resource is unobservable`, and `aws-test/observe` reports
  `AwsStackCreationWireSelectRefused` because no cycle was ever reserved for its
  registered-stack-generation series. No counterexample is registered for those until a run reports
  an exact cause for them.
- `CASCADE-QUALIFICATION-AWS-STACK-READER-SCOPE-DNS-ZONE-ERASED-2026-09-10` is closed code-locally.
  Sprint `7.36` added the run's retained DNS hosted zone to `ObservationEvidenceScope` and Sprint
  `7.38` sealed it into the compiled observation scope, but the Authority AWS stack-reader
  projection was never widened for it: its `ScopeWire` carried no zone field, so `scopeToWire`
  dropped the zone and `scopeFromWire` rebuilt every decoded scope through the zone-less minter.
  The bundle a run had just committed therefore decoded to a different scope than the one the
  caller held, and the exact identity comparator correctly refused it. The zone now travels in
  `ScopeWire` and is rebuilt through `mkObservationEvidenceScopeWithDnsZone`, an invalid encoded
  zone is a closed field refusal, and the zone joins the canonical identity fields so two scopes
  differing only by zone no longer share a submission key. Both encodings advance to format
  version **2** and refuse version 1 rather than upgrading it, because a version-1 object's
  submission key was derived from the zone-less canonical identity and no version-2 read ever
  addresses one. The focused Authority stack-reader group passes **12/12** at
  `/tmp/prodbox-sprint-6.5-stack-reader-dns-zone-focused.log`,
  `sha256:299b82e2db81eb1ca0c42fd7c6e6161143030ab3659245a219cc990e49673d55`, proving zone-bearing
  round trip, zone-less round trip, and distinct submission keys for absent, present, and different
  zones.
- `CASCADE-QUALIFICATION-PROVIDER-EVIDENCE-REFUSAL-UNDIAGNOSABLE-2026-09-10` is closed code-locally
  without changing a single bound. `validateExecutionEvidence` applied three rules — empty, over
  4,096 characters, and control-bearing — and collapsed all three into one text, which is why the
  live 503 could not be attributed. Each rule now names itself and the oversize rule reports the
  length it measured against the named maximum; the evidence itself is a sealed capability
  projection and never enters the refusal. The bound stays at exactly 4,096 characters, so the next
  live run reports which rule fired and by how much and any bound change is made against a
  measurement rather than an inference. The focused Provider Worker execution boundary group passes
  **28/28** at `/tmp/prodbox-sprint-6.5-provider-evidence-rule-focused.log`,
  `sha256:ebcb92dd8bc845d1db2d7a1b12bc077dbe26e13c91059ff1ffe566c7b38fb88c`, covering the empty,
  oversize, control-character, and exactly-at-bound cases.
- Exact-state full unit passes primary **4,906/4,906** and auxiliaries **27/27**, **35/35**, and
  **39/39** at `/tmp/prodbox-sprint-6.5-stack-reader-dns-zone-unit.log`,
  `sha256:4a687c5bf3ebfa9e14a96c4cf5427cca3d90a9c02bc6cbe8b03f86303ae0857a`. Canonical `prodbox dev
  check` exits **0** with pinned Fourmolu, HLint `No hints`, generated-artifact and documentation
  checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-stack-reader-dns-zone-dev-check.log`,
  `sha256:3fca7af5be9f21d7e6cba67eeb5268e48744a4441a215cb0170ebce16913505c`; the synchronized
  executable is exact at
  `sha256:23f0c13d781f7e49d14463e1e745e7eb4432365e7230c9cd3328ff83ff57afc8`. Run distinct live cycle
  `recovery-stack-reader-dns-zone` next; the legacy public writer remains sole and no qualification
  artifact or activation witness exists.
- Live `recovery-stack-reader-dns-zone` runs **2026-09-10 18:15:29–19:17:52 EDT** and live-closes
  both counterexamples the prior cycle registered. It builds local image
  `sha256:2fd0be08ba958743ebcb58f2905c799954fdcdb652f5ef5235640ecab51c0467` in **1,132.0 s**,
  publishes Registry manifest
  `sha256:aedec5b08bfa7cf5e54cfab99ec71b42ffdeff154a7992199b9e01ee8387c2ae`, and imports OCI
  manifest `sha256:f34a1eafc252266d8f1c63332ead2e8e4e24f00ebcc50df1569f364cbc92c8d4` in **97.0 s**;
  retention removes only the immediately superseded Registry manifest `sha256:1c3cfd0b...` and local
  image `sha256:bfc3004b...`. Provider Worker is again **1/1 Ready with zero restarts**.
  `lifecycle/target/aws-eks/read-back-aws-stack-reader-bundle` now **succeeds**, which live-closes
  `CASCADE-QUALIFICATION-AWS-STACK-READER-SCOPE-DNS-ZONE-ERASED-2026-09-10`: the committed bundle
  and its independent read-back agree on the complete scope including the run's hosted zone.
  `lifecycle/target/aws-eks/commit-eks-drain-intent` still refuses, but now with an attributable
  cause — `ProviderIntentExecutionEvidenceInvalid "provider evidence is invalid: provider evidence
  is 4649 characters, over the maximum of 4096"` — which live-closes
  `CASCADE-QUALIFICATION-PROVIDER-EVIDENCE-REFUSAL-UNDIAGNOSABLE-2026-09-10` and replaces the prior
  inference with a measurement. `lifecycle/target/aws-eks/reconcile-absent` is now blocked on
  `read-back-eks-kubernetes-drain` rather than on the stack-reader read-back, so the cascade tail
  moved one branch closer. The candidate emits governed evidence
  `.test-data/qualification/cascade-2f1acdac14071d5af50554fb.evidence` with governed digest
  `3ef98fafce089400416eb2bd320d01e19033385628901f70a9ffe52da79d2ee0` and file SHA-256
  `d5255bb8bf3d0ead3b12bea5f25fe09c554933b0cae014187d425e51d3873e72`, under run
  `cascade-qualification-recovery-stack-reader-dns-zone`, graph digest
  `c58cd5b59ce7e7e6f4c5b01e36e455253022125f134416f79c64ba913ba7658d`, and primary outcome
  `CleanupPrimarySucceeded`. The run exits **1** without exact terminal cleanup and preserves
  operational credentials; no qualification artifact or activation witness exists and the legacy
  public writer remains sole. The transcript is
  `/tmp/prodbox-sprint-6.5-stack-reader-dns-zone-live-recovery-stack-reader-dns-zone.log` at
  `sha256:5b8c574eaa43b0ae0d7e4a67be6053e9435e6908195cfb88cb741509f40a4bac`. This run also emits one
  new non-fatal narration, `public-edge cert retain-on-ready failed (non-fatal):
  TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`, which is recorded and deliberately
  unattributed; it did not stop the restore or the candidate.
- Stable counterexample `CASCADE-QUALIFICATION-EKS-CLIENT-AUTH-EVIDENCE-OVER-BOUND-2026-09-10` owns
  the measured boundary and is closed code-locally. `IssueEksClientAuth` is the only Provider intent
  whose evidence is a sealed capability projection rather than a short observation, and it shared a
  4,096-character bound with every other intent, so no successful client-auth execution could ever
  have satisfied it. The bound is now per intent and total over the closed intent set: every other
  constructor keeps exactly 4,096, and `IssueEksClientAuth` gets a bound **derived** from the
  envelope its sealer may produce rather than a chosen number. The derivation is made exact in both
  directions. Certificate-authority and bearer field maxima drop to 8,192 characters each, roughly
  four and six times the largest values a real EKS cluster returns; the sealed-envelope maximum
  drops to **24 KiB**, above the complete maximal-field plaintext with its framing; and the evidence
  bound is the marker plus the Base64 expansion of that envelope, exactly **32,793** characters,
  which is under the 64 KiB Provider response maximum with roughly half of it to spare. The evidence
  marker itself is now one named constant that the producer and the consumer both use, so the bound
  cannot drift from the string it measures. The focused encrypted EKS client-auth projection group
  passes **9/9** at `/tmp/prodbox-sprint-6.5-eks-client-auth-evidence-bound-focused.log`,
  `sha256:1ffc41fd5be8b2b091d4c7d85ed6e0f1e1d543260244dda3d02c8a051416603e`, proving the complete
  chain: a maximal-field projection seals within the envelope bound, its marker-prefixed evidence
  sits within the derived character bound, that bound sits under the Provider response maximum, a
  live-shaped projection exceeds the superseded 4,096-character bound while fitting the derived one,
  and one character past either field maximum is a closed field refusal.
- Exact-state full unit passes primary **4,907/4,907** and auxiliaries **27/27**, **35/35**, and
  **39/39** at `/tmp/prodbox-sprint-6.5-eks-client-auth-evidence-bound-unit.log`,
  `sha256:06c000d28e1a67d9a45d1b74842fc03295f1e03fb044c1c1ae5bf380333b8026`. Canonical `prodbox dev
  check` exits **0** with pinned Fourmolu, HLint `No hints`, generated-artifact and documentation
  checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-eks-client-auth-evidence-bound-dev-check.log`,
  `sha256:fc3f30b3cb0b28737e232329f7f1074ca58fd26c9aee7f9f6219c735d2d76652`; the synchronized
  executable is exact at
  `sha256:1f078a9af909f84088a999b5197725766efdc4965df434c500dd9bdcba196445`. Run distinct live cycle
  `recovery-eks-client-auth-evidence-bound` next; the legacy public writer remains sole and no
  qualification artifact or activation witness exists.
- Live `recovery-eks-client-auth-evidence-bound` runs **2026-09-10 19:52:13–20:55:28 EDT**. It builds
  local image `sha256:4d7dc7d71d09a2b6b2cb372c759ea497448f5848743db06c39219a7ccd3b24dd` in
  **1,143.5 s**, publishes Registry manifest
  `sha256:e6f2ea22dfbdff2785b7d8dd61622b9d7ee8e23c52095dcf9b71fd61bd158690`, and imports OCI manifest
  `sha256:93aede445a8a59708f8a9d25c88a26a65e69612a057acbecddc98f42b44517f7` in **98.8 s**; retention
  removes only the immediately superseded Registry manifest `sha256:aedec5b0...` and local image
  `sha256:2fd0be08...`. Provider Worker is Ready and the restore's public-edge certificate retains
  cleanly again, so the prior run's non-fatal TLS-retention narration does not reproduce and remains
  unattributed. The Provider **503** is gone: the worker now produces and returns the sealed
  client-auth evidence, which live-closes
  `CASCADE-QUALIFICATION-EKS-CLIENT-AUTH-EVIDENCE-OVER-BOUND-2026-09-10` on the Provider side.
  `lifecycle/target/aws-eks/commit-eks-drain-intent` nevertheless still refuses, one hop later and
  from the other side of the boundary, at `AuthorityProviderRemoteRefused 409 "provider completion
  evidence is invalid"`. The candidate emits governed evidence
  `.test-data/qualification/cascade-ddd397a428449ec81018e576.evidence` with governed digest
  `487d31deee4dcc0d9c01179f7c8aad08a7d9addf2ea983fca7eb36ed4e51ef83` and file SHA-256
  `60eb375859edda92e4991f662fd3d7e3e0c3756340e003de135134c1cb1cf4cf`, under run
  `cascade-qualification-recovery-eks-client-auth-evidence-bound`, graph digest
  `ab15364449a176032df60116033c4b6db686292d04546b41cd892dbac3a34efd`, and primary outcome
  `CleanupPrimarySucceeded`. The run exits **1** without exact terminal cleanup and preserves
  operational credentials; no qualification artifact or activation witness exists and the legacy
  public writer remains sole. The transcript is
  `/tmp/prodbox-sprint-6.5-eks-client-auth-evidence-bound-live-recovery-eks-client-auth-evidence-bound.log`
  at `sha256:6b4824af0baa10e1f5e89ef8543520151fb0a145b8d91aa8230c3714c91a5891`.
- Stable counterexample `CASCADE-QUALIFICATION-AUTHORITY-EVIDENCE-BOUND-DUPLICATED-2026-09-10` owns
  that 409 and is closed code-locally. The Provider Worker and the Lifecycle Authority each carried
  their **own** copy of the 4,096-character evidence rule — the Authority's as a bare `Bool` with no
  diagnostic — so correcting the Provider alone moved the refusal from a 503 to a 409 without
  changing the outcome, and the Authority's copy said nothing about why. The rule is now one total
  function beside the intent it classifies: both the worker that produces the evidence and the
  authority that settles it call it, so the two bounds cannot drift again, and the Authority refusal
  names the rule and the length it measured exactly as the worker's does. No bound changes in this
  correction beyond the per-intent derivation the prior one established. The focused Lifecycle
  Provider admission epoch group passes **12/12** at
  `/tmp/prodbox-sprint-6.5-authority-evidence-bound-focused.log`,
  `sha256:d2684e7f4297262249419071b72cdf55170833930b68ba6c433703825a9e5b49`, proving that the
  Authority refuses an empty and an over-bound observation by name, admits one exactly at the bound,
  admits the live-measured 4,649-character sealed projection under `IssueEksClientAuth`, still
  refuses the same string under a short-observation intent, and reads exactly 32,793 and 4,096 for
  the two bounds.
- Exact-state full unit passes primary **4,908/4,908** and auxiliaries **27/27**, **35/35**, and
  **39/39** at `/tmp/prodbox-sprint-6.5-authority-evidence-bound-unit.log`,
  `sha256:3d16e83d73409ae517173a858c772538a8cb16fd6b952b8a9c1c1b3dc3b07882`. Canonical `prodbox dev
  check` exits **0** with pinned Fourmolu, HLint `No hints`, generated-artifact and documentation
  checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-authority-evidence-bound-dev-check.log`,
  `sha256:6a3095f200f491704bacdfbfa4ad62f6c87a35f6d507d74cf52856ede3524ce6`; the synchronized
  executable is exact at
  `sha256:731c1210169ff4cc8e7e1ce882013568a66f06c8277faa3fefaae8e64f94f72a`. Run distinct live cycle
  `recovery-authority-evidence-bound` next; the legacy public writer remains sole and no
  qualification artifact or activation witness exists.
- Live `recovery-authority-evidence-bound` runs **2026-09-10 21:35:16–22:37 EDT** and stops earlier
  than any prior cycle in this series, inside the retained-home restore and before candidate
  dispatch, so it neither proves nor disproves the Authority evidence-bound correction. It builds
  local image `sha256:245d7df84baf50beee081a4a9abbb2604a92544ba2a5a3abe36bdb8fba392bec` in
  **1,142.1 s**, publishes Registry manifest
  `sha256:6764b40e1512a1415a04596794df58eb1fbff00b0eaa5e55236a87edde7e3bb3`, and imports OCI manifest
  `sha256:fc5aa0273815c94979a40d888b038444b34ab4044e53b37f17937187e633c891` in **95.9 s**; retention
  removes only the immediately superseded Registry manifest `sha256:e6f2ea22...` and local image
  `sha256:4d7dc7d7...`. `RestoreNodeReconcileChart RestoreChartVscode` then fails with
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable` as its entire output, the public-edge
  Gateway and Certificate are never created, and `RestoreNodeWaitForPublicEdge` exhausts its budget
  at `CLASSIFICATION=certificate-not-ready` with `CERTIFICATE_READY=missing`. The run exits **1**,
  preserves operational credentials, emits no governed evidence, and leaves the legacy public writer
  sole. The transcript is
  `/tmp/prodbox-sprint-6.5-authority-evidence-bound-live-recovery-authority-evidence-bound.log` at
  `sha256:e00a1ecb2f9cc56b91fdf93a90585a5acde51b2bf0112482b93a72181b599d73`. The same selected-agent
  refusal appeared once before as a **non-fatal** retain-on-ready narration and once not at all, so
  its severity, not its existence, is what varies with where in the restore it lands.
- Stable counterexample `CASCADE-QUALIFICATION-TLS-SESSION-CLEANUP-CAUSE-DISCARDED-2026-09-10` owns
  the exact attribution failure this exposed, and is closed code-locally. Assembling the cause
  required reading three separate protected logs, and the chain still ended in an opaque token. The
  host transcript carried only the deliberately payload-free
  `TlsRetentionWorkflowAuthoritySelectedAgentUnavailable`; the Lifecycle Authority's protected log
  narrowed it to `selected-agent/http-status/target/prepare/one-shot-operation-unavailable`; the
  Target Agent's own protected log narrowed it to
  `target-one-shot/tls-prepare failure=coordinator/session-cleanup-failed`, and stopped there. The
  coordinator had in fact captured a bounded 256-character cause for the failed session close, and
  the agent-local protected renderer discarded it through a wildcard arm into the payload-free wire
  code — while the symmetric *prepare* failure already had an exact closed classification that the
  same renderer prints in full. Session close now classifies exactly as session prepare does, so the
  one place the cause can legitimately be observed records it. The wire projection is unchanged and
  remains payload-free, and an unrecognized shape reports that it was unrecognized rather than
  echoing interpreter text that could carry a Vault accessor or journal value. The focused attested
  one-shot Target materializer group passes **42/42** at
  `/tmp/prodbox-sprint-6.5-session-cleanup-cause-focused.log`,
  `sha256:016bf9407d48245112544179710e3cd39571db56b55fc51bc18911b1b1757aa0`, covering every
  lifecycle-error shape, the thrown-cleanup case, and the unrecognized case.
- This is the fourth member of one defect class the campaign has now closed at four successive
  layers: an exact typed failure discarded at a classification boundary, leaving a live refusal with
  no attributable cause. The Provider Worker's collapsed evidence refusal, the Lifecycle Authority's
  duplicated bare-boolean copy of the same rule, and now the Target Agent's discarded session-close
  cause were each found only because the layer beneath had already been made to say what it knew.
  No further member of the class is registered speculatively; the next one, if it exists, is
  expected to surface the same way.
- Exact-state full unit passes primary **4,909/4,909** and auxiliaries **27/27**, **35/35**, and
  **39/39** at `/tmp/prodbox-sprint-6.5-session-cleanup-cause-unit.log`,
  `sha256:afcd1076388f448a6917a2696a916b7f081c1d4df5a79535601496e0e289430e`. Canonical `prodbox dev
  check` exits **0** with pinned Fourmolu, HLint `No hints`, generated-artifact and documentation
  checks, and warning-clean all-target compilation at
  `/tmp/prodbox-sprint-6.5-session-cleanup-cause-dev-check.log`,
  `sha256:3c8de69f7c0832f479db2904aa56e60a8c448a8f0068a77f45e2c8d56a595c75`; the synchronized
  executable is exact at
  `sha256:0270147d0cf9a9ee6eff5a1daff9d0abbc1253ff683a6b31a603e7874197e8e2`. Run distinct live cycle
  `recovery-session-cleanup-cause` next. It must do two things: read the newly classified
  session-close cause if the selected-agent refusal recurs, and, if the restore instead completes,
  carry the still-unproven Authority evidence-bound correction through to the EKS drain commit. The
  legacy public writer remains sole and no qualification artifact or activation witness exists.
- Live `recovery-session-cleanup-cause` runs **2026-09-10 23:07:53 – 2026-09-11 00:10:44 EDT** and
  live-closes `CASCADE-QUALIFICATION-AUTHORITY-EVIDENCE-BOUND-DUPLICATED-2026-09-10`. It builds local
  image `sha256:3c765f2b575f977f8e64cb7be5ed3add805a6c58aa569194a597cb1bf4745ac1` in **1,126.6 s**,
  publishes Registry manifest
  `sha256:064af5d1c4b7dc89a033f7d2aa829fb3ed68c4ccefcafe327a3a652292ec475c`, and imports OCI manifest
  `sha256:99bb8f7c5eb5ea067df0f0de7703833605f966c8ff8ed34b9d992491579ea6a8` in **90.2 s**; retention
  removes only the immediately superseded Registry manifest `sha256:6764b40e...` and local image
  `sha256:245d7df8...`. The prior cycle's selected-agent refusal does **not** recur: the vscode chart
  reconciles, the public edge comes up, and the run reaches candidate dispatch. The **409** is gone.
  The EKS client-auth projection now settles end to end, which proves both halves of the evidence
  bound live — the Provider Worker produces the sealed projection and the Lifecycle Authority
  accepts it — and `lifecycle/target/aws-eks/commit-eks-drain-intent` advances past auth acquisition
  for the first time in this series. It then stops at the **next** step, observing the EKS cluster's
  Kubernetes UID, with `EksDrainCommitSelectionKubernetesUidUnobservable (ObservationFailure "failed
  to execute bounded kubectl: AppError {errorKind = Fatal, errorMsg = \"bounded subprocess exceeded
  its wall-clock timeout\", errorCause = Nothing}")`. The candidate emits governed evidence
  `.test-data/qualification/cascade-59f753a756cc23d3a1536197.evidence` with governed digest
  `1ea8a7bba084c8add50af225b3f9b57dce4bf72f699a63194f4736ce289a8ebc` and file SHA-256
  `2797b76472fe4fe0c07e45a5eee1b0c7a705caa6e8a27a5a0c5126eb23b7f874`, under run
  `cascade-qualification-recovery-session-cleanup-cause`, graph digest
  `d5a0934309d2ab277f48e0af85e7276b0ca5457e8b2931b92e26a825f2c1e167`, and primary outcome
  `CleanupPrimarySucceeded`. The run exits **1** without exact terminal cleanup and preserves
  operational credentials; no qualification artifact or activation witness exists and the legacy
  public writer remains sole. The transcript is
  `/tmp/prodbox-sprint-6.5-session-cleanup-cause-live-recovery-session-cleanup-cause.log` at
  `sha256:2c045baf11b343d60eba3c3075bfb8b59788714dfa7d1980a24b95b2967e962b`.
  `CASCADE-QUALIFICATION-TLS-SESSION-CLEANUP-CAUSE-DISCARDED-2026-09-10` stays code-locally closed
  and **not** live-closed: its refusal did not recur, so the newly classified session-close cause was
  never exercised live. Its severity, not its existence, varies with where in the restore it lands,
  and it remains the campaign's one known intermittent restore hazard.
- Stable counterexample `CASCADE-QUALIFICATION-EKS-DRAIN-UID-KUBECTL-TIMEOUT-2026-09-11` owns that
  new boundary and no code change is licensed for it yet. The refusal is already exact and
  attributable — a named selection step, a named subprocess, and a named wall-clock exhaustion — so
  unlike the four preceding members of the attribution class this one needs measurement rather than
  diagnostics. Establish, before changing any budget or recovery semantics, whether the bounded
  `kubectl` reached the EKS API server at all, what the observed round-trip is against a live
  cluster from the home control plane, and what the step's current wall-clock bound is; a bound
  raised without that measurement would be the same inference this campaign has twice replaced with
  a number.
- `CASCADE-QUALIFICATION-EKS-DRAIN-UID-KUBECTL-TIMEOUT-2026-09-11` is measured, and the measurement
  refutes the obvious reading. A read-only probe reproduced the exact `EphemeralKubectl` mechanism —
  private kubeconfig, FIFO `tokenFile`, forever-reopening writer, bounded subprocess — against the
  home API server and against a blackholed endpoint. Three results. **Falsified 2026-09-11 — the
  first of the three is wrong, and the error is instructive.** The probe reproduced the mechanism
  from its doctrine description rather than by linking the compiled module: its writer was a shell
  loop, whose blocking open waits for a reader, where production's Haskell writer opens non-blocking
  and dies. The shell reproduction therefore exonerated a mechanism that has never worked, and cost
  a wrong root cause, a landed correction, and a live cycle. A reproduction probe must link the
  compiled module or re-exec the shipped binary. The sentence as written read: the mechanism itself
  is not a suspect: five consecutive authenticated calls through the FIFO token path completed in
  **40–52 ms**, and the resulting `403` proves the token was read and accepted. `kubectl get namespace … -o
  jsonpath=` against an unreachable endpoint costs **25.05 s**, emitting exactly five `couldn't get
  current server API group list` errors and never reaching the namespace; the same call at a
  2-second request timeout costs **10.04 s** and at 3 seconds **15.04 s**, always with exactly five
  discovery errors, so the multiplier is a fixed retry count and the cost is
  `attempts × request-timeout`. The same resource read through `kubectl get --raw
  /api/v1/namespaces/kube-system` costs **5.04 s** unreachable with **zero** discovery requests, and
  **51 ms** against the healthy API server returning the byte-identical UID
  `16522627-932a-43b6-a7b4-0e566895ab88`.
- Two conclusions follow, and the second is the one that matters. First, the step spent its budget on
  API-group discovery it never needed: the cluster UID is a core `v1` object addressable by path.
  Second, the live failure exceeded **30 s**, which is *more* than the 25.05 s an unreachable
  endpoint costs — so the endpoint was not simply unreachable, and discovery was making partial
  progress against a real API surface at latency, issuing more bounded requests than the
  unreachable case ever reaches. That rules out "the cluster was gone" as the explanation and leaves
  the discovery walk itself as the cost.
- The correction is derived from those numbers rather than chosen. The UID observation now addresses
  the namespace document directly through `--raw` and parses `metadata.uid` from the API's own
  response, so it pays one request instead of six and a missing, empty, or non-object body is a
  closed refusal rather than an absent UID. Every ephemeral `kubectl` call now carries the named
  per-request bound, because a call without one leaves the outer wall clock as its only bound and its
  own exact error can then never be the reported cause. The wall clock is itself derived:
  `(discovery attempts + 1) × request timeout` is the six-request worst case at exactly **30 s**,
  which is precisely the flat bound the live run raced, so the bound is now that sum plus a bounded
  **10 s** margin covering process spawn, the FIFO rendezvous, and TLS — measured together at 65 ms.
  **Falsified 2026-09-11:** there is no FIFO rendezvous in production — the open never completes —
  so this margin is derived from a measurement of a mechanism that does not occur. Sprint `7.39`
  re-derives the bound against the credential mechanism that ships.
  Any inner failure therefore surfaces before the outer bound, which is what makes the next such
  refusal attributable instead of opaque.
- The focused exact EKS drain interpreter group passes **25/25** at
  `/tmp/prodbox-sprint-6.5-eks-drain-uid-focused.log`,
  `sha256:8d395e4f28653430349f76c577dd5cf4f335bd6dd6c81fc7424756d7ba7319cd`, pinning the measured
  retry count and per-request bound, asserting the wall clock strictly exceeds the six-request worst
  case and equals the subprocess limit, and covering the namespace-document parse for the exact UID,
  a missing UID, an empty UID, missing metadata, a non-object body, and unparseable bytes. Exact-state
  full unit passes primary **4,911/4,911** and auxiliaries **27/27**, **35/35**, and **39/39** at
  `/tmp/prodbox-sprint-6.5-eks-drain-uid-unit.log`,
  `sha256:4e8992b8b4b3c5302c150c5e0009de74dd741b353b3e5b71fa87170ba9f6dd7d`. Canonical `prodbox dev
  check` exits **0** at `/tmp/prodbox-sprint-6.5-eks-drain-uid-dev-check.log`,
  `sha256:ab5c3827e50aade46556707e13049ddc820a64a9c3b4fef8d44db1131ea608d9`; the synchronized
  executable is exact at
  `sha256:81e8503c936a517e5e87dc1825748ae9278a1f8603e8d187ebcde189ab848556`. That gate first failed
  on an unrelated governed-document defect: `documents/engineering/vault_doctrine.md` carried two
  leading spaces on its mandatory `**Status**:` field. The indent was removed and nothing else in
  that file changed. Run distinct live cycle `recovery-eks-drain-uid-raw` next; the legacy public
  writer remains sole and no qualification artifact or activation witness exists.
- Live `recovery-eks-drain-uid-raw` runs **2026-09-11 08:28:40–09:32:51 EDT** and refutes the
  discovery explanation. It builds local image
  `sha256:3b599e09ec0081f1d28c801a0e055f06f7c2b8f57854cbbde5aaba5b0bf968fb` in **1,139.0 s**,
  publishes Registry manifest
  `sha256:23872663d9724009e1add2ae5d5d22c3a21e8f27209fc477b87bc098063b26b0`, and imports OCI manifest
  `sha256:c5f1a1b2d9a9bfefec7c031e6e2db43f10c38ed4ab3a7b10b9158ab23d3f2cb2` in **103.6 s**; retention
  removes only the immediately superseded Registry manifest `sha256:064af5d1...` and local image
  `sha256:3c765f2b...`. The restore completes, the candidate dispatches, and governed evidence
  `.test-data/qualification/cascade-3bde7f0f0e7ad2093eb4f135.evidence` is emitted with governed
  digest `1d5aaf04012aed53f41e218b813ca5a4cb321b4927c04cc368ee5f99c22d2f66` and file SHA-256
  `ecef4243fdd2e91287dc3d75eb7149ea66f24ea83859b43fe5f9f50ae970b8b5`, under graph digest
  `c66518269b5d92055ec7f9b1f743c3de5e72e68e2645d543ecead64a400dcf96`. But
  `lifecycle/target/aws-eks/commit-eks-drain-intent` still fails at exactly the same
  `EksDrainCommitSelectionKubernetesUidUnobservable … bounded subprocess exceeded its wall-clock
  timeout`, now with a one-request `--raw` call under a 40-second bound. The run exits **1**,
  preserves credentials, and leaves the legacy public writer sole. The transcript is
  `/tmp/prodbox-sprint-6.5-eks-drain-uid-live-recovery-eks-drain-uid-raw.log` at
  `sha256:33d5300ab05471328f9eb4d5984bba6bbb238bbbc50139eddcb4c74b5cf9de10`.
- The decisive observation is that the duration tracks the bound rather than the work: 30 s under a
  30-second bound, 40 s under a 40-second bound. A call doing bounded HTTP work does not scale with
  its supervisor's timeout; a call that never completes does. The cause is the bearer-token FIFO, not
  the network, and it is now proven rather than inferred. Holding the subprocess runner, the
  kubeconfig, and the argv constant and changing only how the token is delivered, a plain private
  token file completes the identical call in **54 ms** and the FIFO consumes the entire bound,
  **40.00 s**, on both a threaded and a non-threaded runtime. Kernel task state during the hang shows
  `kubectl` parked in `wait_for_partner` with the FIFO absent from its descriptor table, which is the
  open of a FIFO that has no writer. A direct probe supplies the mechanism: GHC opens a FIFO with
  `O_NONBLOCK`, so `ByteString.writeFile` on one with no reader does not wait — it throws `ENXIO`
  immediately. The standing `forever (ByteString.writeFile …)` writer therefore throws on its very
  first attempt, before `kubectl` has started; `forever` propagates it, the thread dies, and nothing
  waits on the `withAsync`, so the death is silent and every subsequent invocation blocks in `open`
  until its supervisor kills it. On this evidence the ephemeral Kubernetes client has never
  authenticated on any live run.
- Stable counterexample `CASCADE-QUALIFICATION-EPHEMERAL-KUBECTL-TOKEN-FIFO-UNSERVED-2026-09-11`
  owns it. **No replacement is landed, deliberately.** Two were built and measured, and both were
  refused by their own measurement: retrying the non-blocking open still lost the race roughly half
  the time even on a threaded runtime, and a blocking `openFd` write-open hung indefinitely and
  produced no result at all. The bearer token must never reach a regular file, so neither dead end
  licenses dropping the FIFO, and a change to how a credential is delivered to a subprocess is a
  Standard-P process-topology surface that an unproven design must not touch. The writer is left
  exactly as it was, carrying the proof at its definition, so the next attempt starts from evidence
  and two eliminated designs rather than from scratch. The supporting `-threaded` change made for the
  blocking-open design was reverted with it.
- What the prior measurement did license is kept, because it is correct independently of this. The
  UID observation reads the namespace document by path with no API-group discovery, every ephemeral
  `kubectl` call carries the named per-request bound so its own error can surface, and the outer wall
  clock is derived as the six-request worst case plus a bounded margin rather than sitting exactly on
  it. The focused exact EKS drain interpreter group passes **25/25** at
  `/tmp/prodbox-sprint-6.5-eks-drain-uid-focused.log`,
  `sha256:39b24a86dfb29cab7c8c320319a0309a0cdfcde7012457177dcdfba9779cd7d9`. Exact-state full unit
  passes primary **4,911/4,911** and auxiliaries **27/27**, **35/35**, and **39/39** at
  `/tmp/prodbox-sprint-6.5-eks-drain-uid-unit.log`,
  `sha256:c5b8b9da29fc85582a0931679a7e028d615169f2c855021f76bd2fb40bdfacf6`. Canonical `prodbox dev
  check` exits **0** at `/tmp/prodbox-sprint-6.5-eks-drain-uid-dev-check.log`,
  `sha256:9645d65b9491ffcd3879bc7677584bda551220c434735cf6cfcbc223ac390e6a`; the synchronized
  executable is exact at
  `sha256:7d4d9ced753a7aa8d56d4d8ae6bc19bf37e83e0120accbbf479248314b18f756`. Design and prove a
  token-delivery mechanism that pairs reader and writer without a regular file before running another
  live cycle; a cycle run before that reproduces this same hang.
- **Corrected 2026-09-11 (Standard C): the instruction in the bullet above was wrong about the
  constraint, and Sprints `7.39` and `7.40` are Done.** "The bearer token must never reach a regular
  file" was a design premise this campaign had been carrying as a finding, and the measurement it
  lacked overturned it. `kubectl` v1.35.8 opens `users[0].user.tokenFile` **exactly twice per
  invocation and independently of how many API requests it makes**, measured under `strace` across a
  zero-request `version`, a one-request `--raw`, and a six-request discovery-bearing `get`. Pairing a
  reader and a writer without a regular file therefore cannot be done at all here: a rendezvous must
  serve a reader whose arrival it cannot observe and whose count it cannot know, which is why both
  eliminated designs failed and why the instruction had no satisfiable solution. The credential is
  now a private file written with `O_EXCL`, `O_NOFOLLOW`, `CLOEXEC` and mode `0600` beside the
  kubeconfig, in the same owner-only directory that dies with the continuation, read back and
  compared before the client value exists. The third statement of the machinery in
  `src/Prodbox/Infra/AwsEksTestStack.hs` is deleted and
  `checkEphemeralCredentialMachinery` holds the machinery to one file. Credential delivery to a
  subprocess remains a Standard-P surface, so this sprint's deployment qualification stays pending
  and no identity captured before that change qualifies afterwards.
- **The next live cycle is admissible and is the campaign's next step.** It is a real experiment
  rather than a rerun of the hang: an EKS drain that reaches and passes
  `lifecycle/target/aws-eks/commit-eks-drain-intent`'s Kubernetes UID observation would be the first
  time any AWS teardown path has authenticated to an EKS API server. The legacy public writer remains
  sole and no qualification artifact or activation witness exists.
- **Live `recovery-ephemeral-credential-file` runs 2026-09-11 22:55:32 → 2026-09-12 00:00:33 EDT and
  the EKS drain authenticates for the first time.** The cycle exits **1** and emits non-qualifying
  evidence `.test-data/qualification/cascade-5fa4e73c9c9b00387639b6a2.evidence`, governed digest
  `94646c92f7f165040692fcd01ddd1e7c9b5517347f1bde9cb9f01ad0d1438deb`, file SHA-256
  `d226cd7da0bb2d7d0a2538290d2100313d10acb19c91b50aec27d777d2b6cbf8`, under graph digest
  `8e5ebb368c01c8a656b4a93b544359eda53f998bb9289992ce1a0d798f5dcb4b`. Transcript
  `/tmp/prodbox-sprint-6.5-live-recovery-ephemeral-credential-file.log` at
  `sha256:76320e314a10bb8496d0243006388c590dfede344bed6a28d474f20f059b1c02`; the synchronized
  executable is exact at
  `sha256:e4ed6986de6f93197120e22964d6565caf4ac4ecf9808c55fd972e6489db70a8`. Credentials are
  preserved and the legacy public writer remains sole.
- **What the run proves, and how the transcript proves it rather than suggesting it.**
  `lifecycle/target/aws-eks/commit-eks-drain-intent` now fails with
  `EksTeardownSelectionFailed (EksDrainCommitSelectionSessionInvalid (EksDrainDeadlineInvalid
  1789184995 1789185895))`. That refusal is reachable only from inside
  `acquireVerifiedEksDrainSelection`'s `EksDrainKubernetesUidPresent` arm: the interpreter reads the
  cluster UID through the ephemeral client first, and only on a *present* UID does it build the
  identity observation and call `mkEksDrainSession`, whose deadline check is the fifth validation in
  that function and sits after `validateKubernetesIdentity` has already consumed the observation.
  `EksDrainCommitSelectionKubernetesUidUnobservable` — the refusal every prior cycle in this
  campaign produced — appears **zero** times in the transcript. The ephemeral Kubernetes client
  authenticated to the EKS API server and returned the cluster UID, which had never happened on any
  live run. Sprint `7.39`'s live half and the live half of Sprint `7.40`'s routing are proven on this
  cycle.
- **Stable counterexample `CASCADE-QUALIFICATION-EKS-DRAIN-LEASE-EXCEEDS-BEARER-EXPIRY-2026-09-12`
  owns what it stopped at, and the mechanism is arithmetic rather than environmental.**
  `mkEksDrainSession` refuses unless `deadline <= projectionExpiry` *and*
  `deadline <= now + maximumEksDrainLifetimeSeconds`, where the second constant is **900**. The
  qualification runner asks for `mkEksDrainLeaseSeconds 900` — exactly the ceiling — and the deadline
  is computed as `now + lease` by `drainDeadline` in
  `src/Prodbox/Lifecycle/Teardown/CloudRuntimeProduction.hs`, before the Provider-issued projection
  that has to back it is minted. A bearer signed at any time at or before that `now` therefore
  expires at or before `now + 900`, so a lease equal to the ceiling can never satisfy the first
  bound. The observed pair is exactly `deadline - now == 900`. The other production caller,
  `src/Prodbox/Test/LifecycleCleanupClient.hs`, asks for 300 and would pass, which is why the defect
  was invisible until a run got this far.
- **No repair is landed for it here, deliberately.** How long a live EKS drain is authorized for is
  a Standard-P surface, and the repair is a design choice rather than a transcription: the deadline
  must be derived from the Provider-issued bearer instead of racing it, which means clamping it at
  the one site holding both — `selectWithProjectionClient` in
  `src/Prodbox/Lifecycle/Teardown/EksDrainInterpreter.hs` — and deciding what to do when the clamp
  leaves less than the drain's own absolute completion deadline of **300 s**
  (`defaultDrainTimeout`). Silently accepting a too-short window would trade this loud refusal for
  an obscure mid-drain timeout, so the shortfall needs a refusal of its own. Choose that floor from
  a measurement of the projection's actual remaining lifetime at this step, which this run did not
  capture: `EksDrainDeadlineInvalid` carries `now` and `deadline` but not `projectionExpiry`, and
  `EksDrainProjectionExpired` did not fire, so all that is proven is `now < projectionExpiry < now +
  900`. Widening that refusal to carry the expiry is the cheapest next measurement.
- **The rest of the run is unchanged from the prior cycle and is not attributed here.** Four
  registered-target observations refuse — `aws-eks-iam-role-family` and
  `dns-aws-dns01-challenge-records` as unobservable, `aws-eks-subzone` and `aws-eks` on
  `AwsStackCreationConfirmationMissing`, and `aws-test` on a series with no reserved cycle — and the
  recovery-plane, EBS, load-balancer-controller and validation-hosted-zone families all complete.
  These stay deliberately unattributed, as they have through this campaign.
- **Three pre-activation defects in this sprint's own machinery are closed (2026-09-11), and none
  of them needed infrastructure to find.** They were found by auditing the sprint's deliverables
  against the tree rather than by a failing run, which is the point: each would have passed every
  test the sprint had.
  **The staged plan gated on nothing.** Its deliverable says the activation and deletion stages
  cannot enter Apply without the matching `QualificationPassed` witness. What existed was an
  ordering fold over a six-constructor enumeration, so a run containing
  `PlanActivateSingleReplacementWriter` and `PlanDeleteLegacyRouteAndIdentity` was constructible with
  no witness in existence anywhere, and `resumeCutoverPlan canonicalCutoverPlan` returned `Right []`
  — the complete cutover accepted on constructor ordering alone. `AdmittedCutoverStage` is now
  opaque and produced only by `admitCutoverStage`, which demands the witness the stage requires
  against the identity it will act on, and the resume fold takes admitted stages rather than named
  ones. `cutoverStageRequiresWitness` is total over the six, and says why the other four must not
  require one: they are what produce the witnesses.
  **`deleteLegacyRoute` took no witness and could leave the identity unchanged.** Being reachable
  only from a private post-activation constructor made it unreachable without a *prior*
  qualification, which is not the same as being gated by one — the witness that authorized
  activation could be for a different identity by the time deletion runs. It now takes the witness
  and refuses a resulting identity equal to the one deleted, because a deletion that changed nothing
  would leave `qualifyPostActivation` satisfiable by the very witness that authorized activation, so
  the deployment would still be called qualified after the source it was qualified on had gone. The
  unit case that demonstrated the hole — deleting with the same identity and replaying the same
  witness — is replaced by one that builds a genuine post-deletion source.
  **The bounded legacy scanner matched substrings and mislabelled a partial removal.** It now
  matches whole identifier tokens, the same rule `Prodbox.Legacy.EscapeRegistry` applies to its seam
  symbols, because a substring rule gets the answer wrong in both directions: it invents a site
  before activation and refuses to call the tree clean after deletion.
  `LegacyCutoverFragmentAbsentFromPath` separates a fragment gone from one registered path while
  surviving in others from one gone everywhere — the former is a half-deleted legacy route, which
  the scan used to report as a duplication carrying a count that was not a duplication count.
  Correcting the match also removed one registration that was an artifact of it:
  `src/Prodbox/Lifecycle/ResourceRegistry.hs` mentions `runNativeDeleteCascade` only in a haddock
  cross-reference, so the two bounded layers now agree — the escape registry's coverage rule for the
  same symbol never listed that file either. Clean-room handoff **20/20**, installed
  `clean-room-handoff` exits 0, primary unit **4,972/4,972**, canonical `prodbox dev check` exits 0.
- **Three current-state claims elsewhere in the tree were false and are corrected (Standard C).**
  `Prodbox.Lifecycle.Teardown.CascadeCandidate.Internal` said nothing in the repository calls its
  entrypoint, which `Prodbox.Test.CascadeQualification` has done since Sprint `4.86` closed.
  `Prodbox.Lifecycle.Decommission.ProgramTag` and its unit case said the images were disjoint across
  *twenty-one* tags and that *three* are two-sided; the measured universe is twenty-two and four.
  `documents/engineering/cli_command_surface.md` said seventeen of twenty-one operations are
  one-sided; it is eighteen of twenty-two, eight compiled-only and ten runner-only. None of the
  three changes what is owed, and all three would have been read as the current state.

### Remaining Work

1. Complete the existing qualification-only runner, type-indexed activation machinery, scoped
   proof-carrying local completion, staged artifact/schema support, mutation-sensitive ordering
   tests, bounded pre/post-activation scanner, and the `runNativeDeleteCascade` conversion received
   from Sprint `4.84`. The Authority Backup rollout counterexample is closed; retain its exact
   requested-revision-plus-availability barrier while completing this work.

   **What is left of this item, stated exactly (2026-09-11).** The qualification-only runner exists
   and is installed; the type-indexed cutover machinery exists, and its staged plan now gates on the
   witness; the bounded scanner exists and now matches tokens and distinguishes a partial removal.
   What remains is the part that cannot be done before activation and the part that must be done
   with it:

   - **No production caller constructs a `CutoverState`.** `initialCutoverState`,
     `activateReplacement`, `deleteLegacyRoute` and `qualifyPostActivation` have no non-test caller,
     so the machinery is a compile-time proof with nothing wired to it. Wiring it is the activation.
   - **The `runNativeDeleteCascade` conversion has not started**, deliberately: this sprint's own
     Sprint-`4.84` handoff says it lands *with* the activation, because converting the legacy caller
     first would build the exact-keyed selection on top of the route the activation deletes.
     `selectRegisteredStackGenerationForCleanup` is reached today only by the replacement path.
   - **The post-activation scan mode has no runtime surface.** `LegacyScanPostActivation` is
     constructed only in tests; the installed validation hardcodes the pre-activation mode. Selecting
     the mode from the cutover phase is part of the activation rather than ahead of it, because
     before activation the post-activation answer is known to be wrong.
   - **Program-tag convergence is eighteen of twenty-two tags** and cannot move until the compiled
     desired-absence program and the signed manifest are one universe, which is what the cutover
     does.
   - **The installed fake traces are of the activated public cascade**, which does not exist yet;
     the five rows that exist today are static constants over the qualification-only summary.
2. Run the complete code-local validation matrix and keep the legacy public writer sole while the
   home qualification row is pending.
3. Run two consecutive home candidate cycles, record the exact current-revision Standard-P
   evidence, consume its witness to activate the sole replacement writer, delete the legacy route,
   and requalify the post-deletion identity before moving ledger rows to Completed. AWS
   adapter implementation/removal remains Sprint `7.36`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - clean-room migration and
  rollback contract.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - generic/home activation and the
  pre-uninstall versus post-uninstall completion evidence boundary.
- `documents/engineering/pure_fp_standards.md` - indexed cutover-state example and illegal-state
  compile checks.
- `documents/engineering/integration_fixture_doctrine.md` - retained-state migration fixtures.
- `documents/engineering/unit_testing_policy.md` - installed-binary interruption matrix.

**Product docs to create/update:**

- `README.md` - handoff and qualification status.

**Cross-references to add:**

- Move legacy rows to Completed only after removal and current-revision qualification satisfy the
  new governance rule.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
