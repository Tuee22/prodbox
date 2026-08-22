# Phase 6: Final Clean-Room Rerun and Zero-Python Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Capture the zero-Python handoff criteria: a full clean-room rerun through the
> Haskell stack and a cleanup ledger where any surviving supported-path residue is explicitly
> owned by its originating phase.

## Phase Status

⏸️ **Reopened and Blocked 2026-08-15 on Sprint `6.5` (Standards A/L/P), blocked by Sprints `4.86`
and `5.36`.** Phase 6 owns the generic/home single-writer cutover, installed-binary clean-room handoff, rollback
rule, and legacy-absence proof for the replacement teardown. The prior clean-room proof exercised
the superseded cascade and cannot qualify this production-composition change. Deployment
qualification remains pending.

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

## Sprint 6.5: Typed Teardown Single-Writer Cutover and Clean-Room Handoff [⏸️ Blocked]

**Status**: Blocked by Sprints `5.36`, `7.36`, and `7.38` (opened 2026-08-15; Sprints `4.86` and
`4.89` closed 2026-08-20 and 2026-08-21 and their entries are gone).
**Blocked by**: Sprint `5.36` for the lifecycle-kernel `TestRunner` client, Sprint `7.36` for
the exact AWS desired-absence adapters its convergence runs over, and Sprint `7.38` for the run's
DNS hosted zone in the compiled program's observation scope. Sprint `4.89` closed on
2026-08-21, so the custodial-capability disposition this sprint's uninstall node consumes is
landed. The complete replacement program Sprint `4.86` owed landed on 2026-08-20: the non-public
candidate entrypoint drives the total dispatcher over a durable descriptor-bound run, and this
sprint activates it.
**Backward dependency**: Sprints `7.36` and `7.38`. `7.36`: the single-writer cutover makes the
compiled desired-absence program and the signed `DecommissionNode` manifest one universe, and every
tag can only become two-sided over the exact AWS desired-absence adapters Sprint `7.36` supplies;
performing the cutover first would activate a public writer whose convergence could not be observed,
leaving the superseded cascade deleted and its replacement unable to prove absence. `7.38`: Sprint
`7.36` registered the DNS01 challenge record family, whose coordinate is a record-name prefix and is
not complete without a hosted zone, and the compiled program's observation scope has no producer for
one — so activating the compiled cascade before `7.38` would delete the superseded writer and leave
the replacement unable to converge on a family it is now obliged to prove absent. Both declared
under
[Standard N.2](../DEVELOPMENT_PLAN/development_plan_standards.md#n-phase-independence-and-execution-order);
the queue runs `7.36` and `7.38` first.
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
`src/Prodbox/Test/Qualification/Evidence.hs`, and the registered retired-symbol scanner.
**Live-proof**: pending and non-blocking for code-local closure. Two consecutive destructive home
cycles run the qualification-only replacement candidate under its exact identity before any public
activation. Standard P forbids activation and legacy deletion until the current-revision home row is
`proven`; the post-activation identity must then be qualified before the ledger row can complete.
**Independent Validation**: pure prefix/resume and rollback folds, installed-binary fake traces,
repository/rendered-resource scans, unit/integration suites, and `prodbox dev check`.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/pure_fp_standards.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/unit_testing_policy.md`, root `README.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/substrates.md`, and `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Build and locally validate the qualification-gated cutover from the handwritten generic/home
cascade to the typed recover-to-clean graph, with one writer, one durable cleanup namespace, and
type-indexed rollback legality. Before qualification, the legacy route remains the sole public
writer and the replacement is callable only by the qualification-only runner. After Standard-P
evidence authorizes activation, consume that evidence to make the replacement the sole public writer
and remove the legacy generic/home path. The AWS adapter slot refuses as unavailable until Sprint
`7.36`; this sprint makes no AWS parity claim.

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
9. Two consecutive home clean-room candidate cycles produce the complete artifacts, uninstall last,
   and leave only intended retained resources. These live results remain non-blocking Standard-P
   evidence and do not themselves make code-local closure contingent on infrastructure.
10. **Received from Sprint `4.86` on 2026-08-20 under
    [Standard N](development_plan_standards.md#n-phase-independence-and-execution-order).**
    Installed-binary fake traces of the activated public cascade cover success, failure,
    cancellation, response loss, restart, and terminal narration, each carrying the exact resource
    keys, observation authorities, and `CleanupRunId`. Sprint `4.86` cannot own this: it
    deliberately activates no public writer, so no installed command's narration exists to trace.
    Held there it was a Phase-4 validation criterion that only this sprint's composition could
    satisfy.

### Remaining Work

Blocked until the replacement cascade and lifecycle cleanup client exist. Once they land, code-local
closure requires the qualification-only runner, type-indexed activation machinery, scoped
proof-carrying local completion, staged artifact/schema support, mutation-sensitive ordering tests,
the bounded pre/post-activation scanner, and the `runNativeDeleteCascade` conversion received from
Sprint `4.84`; it does not require live infrastructure. Public
activation and legacy generic/home deletion remain prohibited while the home qualification row is
pending. After that row is proven, Sprint `6.5` consumes its exact witness, activates one replacement
writer, deletes the legacy route, and requalifies the changed identity before moving ledger rows to
Completed. AWS adapter implementation/removal remains Sprint `7.36`.

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
