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

**Status**: Active (resumed 2026-08-31). The former gates are complete: Sprint `5.36`
landed the lifecycle-kernel `TestRunner` client, Sprint `7.38` sealed the run's DNS hosted zone into
the compiled observation scope, Sprint `4.89` landed the custodial-capability disposition, and
Sprint `4.86` landed the non-public candidate entrypoint that drives the total dispatcher over a
durable descriptor-bound run. This sprint activates that replacement.
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

### Remaining Work

1. Complete the existing qualification-only runner, type-indexed activation machinery, scoped
   proof-carrying local completion, staged artifact/schema support, mutation-sensitive ordering
   tests, bounded pre/post-activation scanner, and the `runNativeDeleteCascade` conversion received
   from Sprint `4.84`. The Authority Backup rollout counterexample is closed; retain its exact
   requested-revision-plus-availability barrier while completing this work.
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
