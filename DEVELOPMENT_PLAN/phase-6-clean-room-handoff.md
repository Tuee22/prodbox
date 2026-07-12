# Phase 6: Final Clean-Room Rerun and Zero-Python Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[substrates.md](substrates.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[lifecycle_control_plane_architecture.md](../documents/engineering/lifecycle_control_plane_architecture.md)
**Generated sections**: none

> **Purpose**: Capture the zero-Python handoff criteria: a full clean-room rerun through the
> Haskell stack and a cleanup ledger where any surviving supported-path residue is explicitly
> owned by its originating phase.

## Phase Status

⏸️ **Reopened and blocked by Sprint `5.19`.** Sprint `6.4` expands the clean-room handoff's
own surface to cover the authority-epoch migration, restart-resume behavior, rollback refusal after
cutover, complete home restoration, and zero surviving legacy gateway authority routes. The June
26 run remains historical proof of the then-current topology; it is not current-revision
qualification for the new process boundary.

✅ **Live-proven 2026-06-26 (home substrate) — the destructive rerun contract holds under the green
`test all`.** The green home `prodbox test all` (2026-06-26, 18/18; see [00-overview.md](00-overview.md)
Alignment Status) exercises the destructive `lifecycle` validation (`cluster delete` →
`cluster reconcile` → `cluster health`) and the suite's per-run AWS-stack provision+teardown to clean
exit with no leaked AWS spend, home-substrate-proving Phase 6's destructive-rerun + zero-Python handoff
contract. The `--substrate aws` rerun coverage remains the orthogonal, non-blocking axis
([substrates.md](substrates.md)).

✅ **Historical narrower surfaces remain done** — Sprints `6.1`–`6.3` remain closed on the destructive rerun
contract and zero-Python handoff surfaces. Per
[development_plan_standards.md](development_plan_standards.md) standards rules E and N, Phase 6
retains those results independently of later phases. They do not prevent the phase from being
reopened when Sprint `6.4` explicitly expands Phase 6's own authority-migration and clean-room
surface; its current blocked status is caused only by the earlier Sprint `5.19` dependency.

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

This phase defines the clean-room and zero-Python handoff criteria for the Haskell-only
repository. It owns the destructive rerun contract, the final zero-Python handoff criteria, and
the forward build-order composition of those surfaces over the earlier lifecycle, gateway, chart,
and AWS phase deliverables. Build order is not a validation gate (Standard N): Phase 6's owned
surfaces are validatable on the home/local substrate independently of any other phase's completion
state. Sprint `6.4` is nevertheless new Phase-6-owned work and legitimately reopens this phase.
The supported repository surfaces are Haskell-only, and the single-host doctrine is implemented.
Sprint `6.1`, Sprint `6.2`, and Sprint `6.3` remain closed on their repository-owned rerun
orchestration, zero-Python baseline, and single-host handoff surfaces. The cleanup ledger remains
clear on Python-removal and single-host handoff residue, and the non-Python doctrine-adoption rows
owned by reopened Phases `1`–`4` are now closed. The historical Python-removal surface retains no
open work; authority migration and current clean-room proof remain open under Sprint `6.4`. The Phase `6` doc-harmony
follow-up to the `METALLB_ENVOY_KEYCLOAK_REDIS_WEBSOCKETS.md` planning-doc deletion is closed in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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

## Sprint 6.4: Clean-Room Authority Migration and Rollback Proof [⏸️ Blocked]

**Status**: Blocked
**Deployment qualification**: pending
**Implementation**: planned clean-room migration fixtures, installed-binary lifecycle traces,
repository absence guards, and handoff evidence under `test/` and `src/Prodbox/TestRunner.hs`
**Blocked by**: Sprint `5.19`
**Live-proof**: pending after code-local preparation; the current-revision home clean-room run is a
deployment-qualification axis rather than phase-status evidence
**Independent Validation**: versioned migration fixtures, dry-run plans, source/route absence
checks, and fake installed-binary traces validate the handoff contract without AWS or a later
phase.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
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

### Remaining Work

- Blocked until Sprint `5.19` supplies the temporal qualification and cleanup recorder.
- The real home clean-room run remains deployment qualification; Sprint `7.33` owns AWS parity.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - clean-room migration and
  rollback contract.
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
