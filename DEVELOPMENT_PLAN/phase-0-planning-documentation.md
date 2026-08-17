# Phase 0: Planning and Documentation Topology for Haskell Rewrite

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Define the plan-ownership baseline for the Haskell rewrite so status, sequencing,
> Python-removal work, and CLI doctrine adoption have one canonical home.

## Phase Status

✅ **Sprint `0.20` (2026-08-03) adopts repository value hygiene on the same already-reclosed Phase 0
documentation/governance surface** — it neither re-closes nor reopens the phase (Sprint `0.17`'s
reclosure below stands unchanged). Every committed value that stands in for real-world data is
officially synthetic, unmistakably synthetic, or genuinely real and declared as such in place
([vault_doctrine.md §20](../documents/engineering/vault_doctrine.md#20-repository-value-hygiene)).
The rule generalizes Sprint `0.19`'s credential-literal invariant to the class that actually leaked:
a real Route 53 hosted-zone id survived seven commits in the version-controlled long-lived stack
settings file, indistinguishable from the synthetic zone ids beside it. Sprint `0.20` retitles §20
from *secret* to *value* hygiene, folds the bootstrap-floor credential registration back into §6.1
where it already lived, reconciles the §17 ownership statement, and scopes Exit Definition item 17 to
runtime surfaces so it no longer contradicts the doctrine's preference for reserved placeholders.
Companion own-surface reopens land the remediation on the phases that own it: Sprint `7.35`
(Phase 7), Sprint `5.26` (Phase 5), Sprint `1.74` (Phase 1).

✅ **Sprint `0.19` (2026-08-03) adds repository secret hygiene on the same already-reclosed surface**
— likewise neither re-closing nor reopening the phase. It established §20 as the SSoT for credential
material in tracked content, removed a vestigial hardcoded registry admin credential that
authenticated to nothing, and corrected the comment sites that mis-stated the MinIO bootstrap
credential's reachability. Superseded in part by Sprint `0.20`, which generalizes the rule and
withdraws the construct-the-value fixture convention in favour of not imitating credentials at all.

✅ **Sprint `0.18` (2026-07-12) adds an operator-configurable certificate-scope governance policy on
the same already-reclosed Phase 0 documentation/governance surface** — it neither re-closes nor
reopens the phase (Sprint `0.17`'s reclosure below stands unchanged). Sprint `0.18` adopts a
Tier-0-configurable certificate-scope policy that makes an unmanaged or uncovered served hostname
unrepresentable on the prodbox-managed side, records the orphan ZeroSSL dashboard-certificate
incident disposition (VS Code stays served at `https://test.resolvefintech.com/vscode` on the shared
public host under the auto-renewing `zerossl-dns01` certificate; the operator revokes the orphan and
unsubscribes from its click-to-renew mail — a manual ZeroSSL-console action), rejects parent→child
certificate-material handoff in favor of delivered `AcmeEabMaterial` self-issuance, registers
implementation Sprints `2.35` (Phase 2) and `5.22` (Phase 5), and retires the root
`ZEROSSL_POLICY.md` into the governed engineering docs. No implementation sprint or deployment
qualification is claimed by this plan-only governance addition.

✅ **Reclosed on its documentation/governance surface in Sprint `0.17` (2026-07-12).** Sprint `0.17`
adopts the Foundation Epoch sequencing correction for counterexample `LCPC-2026-07-11`: Standard P
gains the interim escape-path guard, Sprints `1.61` / `1.62` are shrink-rescoped, Sprints
`1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34` are registered with their deletion-ledger
rows, and the compiled-boundary, durability-index, derived-restore, and measured-capacity doctrine
is encoded in the governed engineering docs. The Foundation Epoch (Sprints `1.63`–`1.66`, `2.34`,
`4.51`, `5.20`, `5.21`, and `7.34`) is the active work front and is executed before Sprints `1.61`
and `1.62` as an execution-priority decision; it introduces no `Blocked by` edge onto the existing
`1.61` → `8.12` chain, which resumes unchanged once the epoch closes. No implementation sprint or
deployment qualification is claimed by this plan-only reclosure.

✅ **Reclosed on its documentation/governance surface in Sprint `0.16` (2026-07-11).** The July 11 full-suite
counterexample showed that code-local readiness closure had been reported as deployment
qualification without exercising the exact production composition. Sprint `0.16` defines the
pure lifecycle-control-plane target, reopens every phase whose own surface expands, and separates
phase completion from revision-scoped deployment qualification. The root documentation, generated-
section, diff, warning-clean build, and mechanical status gates passed on 2026-07-11; no
implementation sprint or deployment qualification is claimed by this plan-only closure.

✅ **Done on owned surface 2026-06-16** — Phase 0 owns the docs / plan-only Sprint `0.15`
(Phase-Independence Doctrine Adoption), which lands the phase-independence doctrine into
[development_plan_standards.md](development_plan_standards.md) as Standards N (Phase
Independence) + O (Code-Local vs Live-Infra Proof) plus amendments to Standards A / C / H / M,
and harmonizes the plan suite and governed docs to it. The doctrine lets every earlier phase be
validated independently of later phases: each phase is validatable on its owned surface (against
the home / local substrate, a fake, or a stub where a dependency is owned by a later phase) even
when any other phase is incomplete; `Blocked by` is forward-only (an earlier-or-same-phase sprint
or an external prerequisite, never a later phase); code-local completion (builds + passes local
validation) is the phase-closure axis, while a proof needing live infrastructure is a
non-blocking `Live-proof: pending` note, not `⏸️ Blocked`; and AWS-substrate coverage of a
suite-content validation is tracked only in `substrates.md`'s parity table, never marking a
suite-content sprint or its phase blocked. The code / live adoption is owned by the reframed
implementation sprints (phase-5 Sprint `5.8`, phase-7 Sprint `7.14` / `7.16`); Phase 0 stays
`Done` on its owned doc / plan surface.

**Independent Validation**: Phase 0 owns the development-plan and governed-documentation surface;
it is validated on that owned surface with no dependency on a later phase via `prodbox dev docs
check`, `prodbox dev lint docs`, and `prodbox dev check` exiting 0, plus a grep replay confirming
no backward `Blocked by` survives — all runnable on the home / local substrate.

✅ **Done on owned surface 2026-06-15** — Phase 0 owns the docs / plan-only Sprint `0.14`
(Model-B Pulumi/MinIO and Whole-System Sealed-State Doctrine Harmony), which refines the
sealed-state architecture in doctrine: MinIO-stored state and Pulumi backend state are encrypted
under **Model B** — a `prodbox` application-level Vault-Transit envelope per object — and the
sealed-Vault invariant is extended to a **whole-system zero-child-info** property covering MinIO
objects, the host disk, Kubernetes objects, and logs / output. Pulumi's own secrets provider is
**dropped** (the `prodbox` envelope is the encryption), the Pulumi backend is interposed through a
decrypt-to-scratch RAM-tmpfs `file://` hydration so Pulumi never touches MinIO, the long-lived
`aws-ses` backend is treated under the **uniform** Vault-envelope (the AES256-SSE-only carve-out is
dropped), object IDs are Vault-keyed-HMAC opaque names, the object count is decoy-padded to a
constant, the stored envelope AAD is hashed (`prodbox-envelope-v2`), and all `prodbox`-owned
secret-bearing state lives in **one generically-named bucket** shared by the host CLI and the
in-cluster gateway daemon. Sprint `0.14` rewrote
[vault_doctrine.md](../documents/engineering/vault_doctrine.md) §9 / §10 / §13 / §14 / §19, the
config / cluster-federation / helm / storage / streaming doctrine docs, the repo-root `README.md`
and `CLAUDE.md`, and the plan suite, and repointed the legacy ledger. This **refines, it does not
reverse**, the 2026-06-14 Vault-root model and **reopens no new phase** — every affected phase
(0 / 1 / 4 / 5 / 7) was already reopened on 2026-06-14. The code adoption is owned by the reframed
and new implementation sprints (`1.37`, `4.30`, `4.33`, `7.14`); Phase 0 stays `Done` on its owned
doc / plan surface.

✅ **Done on owned surface 2026-06-14** — Phase 0 owns the docs / plan-only Sprint `0.13`
(Vault-Root Finalization and Cluster-Federation Doctrine Harmony), which finalizes the secrets
architecture in doctrine: Vault is the sole, fail-closed secrets / KMS / PKI root; the master-seed
HMAC derivation model is **retired** (not extended — this supersedes the Sprint `0.12` framing);
`SecretRef.FileSecret` and Secret-mounted plaintext Dhall fragments are **removed** (not bridged);
a sealed Vault bricks the cluster; and cluster federation adds a Vault transit-seal trust tree
governed by the new [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md).
Sprint `0.13` rewrote [vault_doctrine.md](../documents/engineering/vault_doctrine.md), the config /
secret-management / helm / storage / acme / aws doctrine docs, the repo-root `README.md` and
`CLAUDE.md`, and the plan suite, added the federation doctrine, and deleted the repo-root
`VAULT_REFACTOR.md`. The code adoption is owned by the new and reframed implementation sprints
(`1.35`–`1.38`, `2.26`, `3.17`–`3.20`, `4.29`–`4.32`, `5.8`, `7.14`–`7.15`, `8.9`); Phase 0 stays
`Done` on its owned doc / plan surface.

✅ **Reclosed 2026-06-09** — Phase 0 was reopened for Sprints `0.9`–`0.10` to make Documentation
Harmony an enforced plan invariant; both have now landed. ✅ **Sprint `0.9`**: the five doctrine
corrections + the repo-wide `**Generated sections**` header sweep, plus the header↔markers↔registry
reconciler + governed-doc relative-link check wired into `runGeneratedArtifactLint` (the sha256-freeze
over-claim struck). ✅ **Sprint `0.10`**: the §2/§3 command matrix (from `commandRegistry`, Sprint
`1.29`) and the registry-name↔CLI-command table (composed with the `StackDescriptor` record, Sprint
`4.27`) are generated sections; the chart→edge-resource ownership table was deliberately left editorial per the design
guardrail (no typed owning-chart source — generating it would relocate drift; Sprint `7.13` owns the
doctrine reattribution). Validation at reclosure: `check-code` 0, `test unit` 802, `lint docs` 0,
`docs check` 0. All earlier Phase 0 sprints (`0.1`–`0.8`) remain `Done`; Documentation Harmony is now
machine-enforced (the reconciler + relative-link check + generated drift-prone tables), not a
periodic manual audit.

✅ **Done (Sprints `0.1`–`0.8`)** — Sprint 0.1 (canonical plan suite for the Haskell rewrite) is `Done`, and the
Phase-0 doctrine-governance reopens scheduled by Sprints `0.2`, `0.3`, `0.4`, `0.5`, `0.6`,
and `0.7` are also now `Done`. Sprints `0.2`–`0.6` adopted
[the engineering doctrine docs](../documents/engineering/README.md) as the authoritative CLI doctrine, aligned the
governed docs and plan suite with that doctrine, scheduled every currently known code-level
adoption gap onto explicit downstream sprints under Phases `1`–`4` per
[development_plan_standards.md](development_plan_standards.md) rule L, reopened Phase `4`
through Sprint `4.8` to harden the user-visible `prodbox rke2 delete --yes` success-summary
contract, and (Sprint 0.6) introduced the substrate doctrine into the canonical phase model:
one canonical test suite that runs against substrates (home local + AWS), renamed
phase-5 to `phase-5-canonical-test-suite.md`, renamed phase-7 to
`phase-7-aws-substrate-foundations.md`, added [substrates.md](substrates.md) as the
authoritative substrate inventory, and added phase-8 for operator-invited email authentication
via Keycloak + AWS SES. Sprint `0.7` (May 20, 2026) added the LLM/automation guardrails on
the interactive command surface: every operator-interactive entry point now refuses to run
when stdin is not a TTY and emits a structured guidance message naming the non-interactive
automation equivalent. Phase `0` is therefore re-closed, and the downstream implementation
work is also reclosed because Sprint `4.8` has landed.

## Phase Summary

This phase establishes the development plan as the canonical execution-ordered record for the
Haskell-only repository. It owns the phase model, the top-level control documents, the cleanup
ledger used by later phases, and — beginning with Sprint 0.2 — the governance contract for the
repository's CLI doctrine. Sprint 0.3 extended that governance contract by scheduling the
residual doctrine gaps surfaced by the post-0.2 audit, ensuring every doctrine-prescribed
behavior that the worktree did not yet honor was owned by an explicit downstream sprint block per
[development_plan_standards.md](development_plan_standards.md) rule L. Sprint 0.4 extended the
same governance contract to the round-3 audit residue, adding the toolchain-pin declarations,
library-first layout audit, daemon-as-typed-`Command` dispatch, typed structured-logging
helpers, AppError record shape, schemaVersion-as-Natural binding, forbidden reload triggers,
forbidden reconciler flags, forbidden subprocess primitives, structured-concurrency primitive
set, property-test invariants, health-endpoint golden-test shapes, renderer-determinism
forbidden inputs, production-no-op / test-injected hook contract, and the
`fourmolu.yaml` 12-setting list as named deliverables on existing planned sprints. Sprint 0.5
extends that governance contract again for the lifecycle delete success-summary (now exposed as
`prodbox cluster delete --yes`)
surface, scheduling hermetic suppression of benign upstream uninstall chatter plus the governed
documentation updates required by
[../documents/documentation_standards.md](../documents/documentation_standards.md). Sprint
0.15 extends the governance contract once more with the phase-independence doctrine, adopting
Standards N (Phase Independence) and O (Code-Local vs Live-Infra Proof) plus the A / C / H / M
amendments into [development_plan_standards.md](development_plan_standards.md) and harmonizing
the plan suite and governed docs so an incomplete later phase can never block, gate, or reopen
an earlier phase.

## Sprint 0.1: Canonical Plan Suite for the Haskell Rewrite ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`, `DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`, `DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`, `DEVELOPMENT_PLAN/phase-2-gateway-dns.md`, `DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md`, `DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`, `DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md` (originally authored as `phase-5-public-host-validation.md`; renamed by Sprint 0.6), `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md` (originally authored as `phase-7-aws-iam-quota-automation.md`; renamed by Sprint 0.6), `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`, `DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Rewrite the canonical plan suite so every phase reflects the Haskell end state and the complete
removal of Python from the supported architecture.

### Deliverables

- The top-level plan docs describe the Haskell rewrite rather than the closed Python architecture.
- Phase names `0-7` are retained, but their owned surfaces now target Haskell implementation work.
- The plan suite defines the build-artifact contract: `.build/prodbox` as the host-side
  operator-facing binary artifact and `/opt/build` in container builds.
- The legacy ledger captures cleanup ownership for Python removal and any later compatibility
  residue.

### Validation

1. `prodbox dev check`

### Remaining Work

None.

## Sprint 0.2: Adopt the CLI doctrine as Governed CLI Doctrine ✅

**Status**: Done
**Implementation**: the engineering doctrine docs, `DEVELOPMENT_PLAN/development_plan_standards.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`,
`DEVELOPMENT_PLAN/phase-2-gateway-dns.md`,
`DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md`,
`DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`,
`DEVELOPMENT_PLAN/phase-5-public-host-validation.md`,
`DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`,
`DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md`,
`documents/documentation_standards.md`, `documents/engineering/code_quality.md`,
`documents/engineering/cli_command_surface.md`,
`documents/engineering/unit_testing_policy.md`,
`documents/engineering/prerequisite_doctrine.md`,
`documents/engineering/haskell_code_guide.md`,
`documents/engineering/refactoring_patterns.md`,
`documents/engineering/effect_interpreter.md`, `README.md`, `AGENTS.md`, `CLAUDE.md`
**Docs to update**: every file listed above.

### Objective

Promote [the engineering doctrine docs](../documents/engineering/README.md) into the governance contract so it is the
authoritative CLI doctrine for the repository, align the development plan suite and governed
engineering docs with the doctrine, eliminate contradictions, and schedule the downstream code
adoption through declared phase reopens.

### Deliverables

- the engineering doctrine docs carry the standard `**Status**` / `**Supersedes**` / `**Referenced by**`
  metadata block and is reachable from every plan document and root pointer.
- `development_plan_standards.md` defines the CLI Doctrine Alignment rule (standards rule L) and
  requires phase docs to cite doctrine sections by name when scheduling adoption work.
- `documents/documentation_standards.md` documents the six Generated Sections requirements named
  by the doctrine: marker syntax per file type with literal `<prodbox>:<key>:start|end`
  examples, an authoritative pointer to the in-code `GeneratedSectionRule` registry, a
  "How to regenerate" instruction naming `prodbox dev docs generate`, a per-file
  `**Generated sections**: <key1>, <key2>` (or `none`) metadata field with a lint contract, a
  five-step extension protocol, and a "fully generated, do-not-hand-edit" rule.
- Governed engineering docs that overlap with the doctrine — `code_quality.md`,
  `unit_testing_policy.md`, `prerequisite_doctrine.md`, `cli_command_surface.md`,
  `haskell_code_guide.md`, `refactoring_patterns.md`, `effect_interpreter.md` — cite the
  doctrine sections they implement, defer to the doctrine on shared topics, and retain only
  project-specific elaborations.
- Root pointers in `README.md`, `AGENTS.md`, and `CLAUDE.md` link to the engineering doctrine docs
  alongside the existing `DEVELOPMENT_PLAN/README.md` link.
- `DEVELOPMENT_PLAN/README.md` and `DEVELOPMENT_PLAN/00-overview.md` declare Phases 0–4
  reopened for doctrine adoption, enumerate the new sprints in each (Phase 1 Sprints
  1.6–1.22 and Phase 2 Sprints 2.9–2.15, where 1.17–1.22 and 2.15 close the doctrine gaps
  identified by the CLI-doctrine adoption audit), and call out the surfaces in
  Phases 5–7 that originally remained closed on their owned scope per standards rule E. Phase
  `5` later reopened separately through Sprint `5.5` for the public HTTP-to-HTTPS redirect and
  re-closed after the May 13, 2026 aggregate validation.
- `DEVELOPMENT_PLAN/system-components.md` lists the new components introduced by the doctrine
  (CLI Spec registry, `GeneratedSectionRule` registry, `forbiddenPathRegistry`, daemon
  `/healthz` / `/readyz` / `/metrics` endpoints, `BootConfig` / `LiveConfig` split, `co-log`
  structured logger, `prodbox-haskell-style` / `prodbox-daemon-lifecycle` / `prodbox-pulumi`
  test stanzas).
- `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` preserves the doctrine-driven removal
  queue history from Phases 1–4 with location, reason, owning sprint, and completed closure
  evidence.

### Validation

1. `prodbox dev check` passes after all Sprint 0.2 documentation edits.
2. `documents/documentation_standards.md` covers every one of the six doctrine-mandated
   Generated Sections elements; a diff against the doctrine's "Project-level documentation
   standards" subsection shows no missing item.
3. Each governed engineering doc named above either cites a doctrine section by name or shrinks
   to a doctrine pointer.
4. Each reopened phase document declares its new sprints per standards rule H, citing the
   doctrine sections they implement.
5. Root `README.md`, `AGENTS.md`, and `CLAUDE.md` link to the engineering doctrine docs.

### Remaining Work

None.

## Sprint 0.3: Audit-Driven Doctrine-Gap Scheduling ✅

**Status**: Done (with May 24, 2026 supersession note on the forbid-fsnotify clause). The
sprint's residual Phase 2 extension that bound `fsnotify`, `inotify`, and `mtime` polling
as forbidden reload triggers is superseded by Sprint 0.8 (pure-Dhall config doctrine
adoption); the daemon's reload trigger becomes a file watcher per
[config_doctrine.md §7](../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger),
and the matching lint-rule removal moves to
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). Every other Sprint 0.3
deliverable stands.
**Implementation**: `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`,
`DEVELOPMENT_PLAN/phase-2-gateway-dns.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: every file listed above.

### Objective

Schedule the residual [the engineering doctrine docs](../documents/engineering/README.md) items surfaced by the
May 2026 doctrine-vs-plan audit so every doctrine-prescribed behavior that the worktree did
not yet honor was owned by an explicit sprint block, per
[development_plan_standards.md](development_plan_standards.md) rule L.

### Deliverables

- Phase `1` sprint range extends to **Sprint 1.26**:
  - **Sprint 1.24: Durable CLI Documentation Artifacts** schedules the Markdown command
    reference, manpages, and shell completion scripts derived from the `CommandSpec`
    registry per [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)and `The Architecture` summary
    §2349–2356. HTML output is recorded as a doctrine-aware deferral until a consumer enters
    scope.
  - **Sprint 1.25: Parser-Test Category via `execParserPure`** schedules the
    `argv → Command` parser-test category per [unit_testing_policy.md#parser-tests](../documents/engineering/unit_testing_policy.md#parser-tests)in addition to the rendered-output golden
    tests already owned by Sprint 1.6.
  - **Sprint 1.26: Error Rendering Boundary Discipline** schedules `renderError :: AppError
    -> Text` at the CLI boundary plus hlint rules refusing `print`, `exitFailure`, and
    direct terminal formatting in non-boundary code, per [haskell_code_guide.md#error-handling](../documents/engineering/haskell_code_guide.md#error-handling).
  - Sprint 1.6 is extended to require at least one `Example` entry per leaf
    `CommandSpec` node (doctrine §299–303), enforced by a `prodbox-unit` property
    test.
  - Sprint 1.10 is extended to require the `cabal format` temp-file round-trip plus
    byte-equality compare during the check pass (doctrine §1834–1837).
- Phase `2` sprint deliverable extensions (no new sprints):
  - Sprint 2.9 names the default 30 s drain deadline (doctrine §1235–1236) and explicit
    `bracketOnError` for resources with external side effects (doctrine §1218–1220).
  - Sprint 2.10 adds `envMetrics :: MetricsRegistry` as a typed daemon `Env` field
    consumed by `/metrics` (doctrine §1357–1366), forbidding module-local mutable
    counter state through the negative-space hlint rules established by Sprint 1.19.
  - Sprint 2.11 adds the STM broadcast channel (`TChan` / `TBQueue`) for `LiveConfig`
    subscribers per the reload procedure's step 8 (doctrine §1528–1531) and the
    prescribed on-disk Dhall file shape with top-level `schemaVersion` / `boot` / `live`
    records (doctrine §1551–1574).
  - Sprint 2.12 names "log level set by `BootConfig` at startup and refreshed from
    `LiveConfig` on every hot reload" as a deliverable, with the reload worker scheduled
    by Sprint 2.11 setting the new level on the `co-log` logger inside its atomic-swap
    step (doctrine §1275–1276).
- `system-components.md` adds rows for: durable CLI documentation artifacts,
  `execParserPure` parser-test category, `renderError` boundary, `envMetrics`
  `MetricsRegistry` typed `Env` field, STM broadcast channel for `LiveConfig`
  subscribers, and the prescribed Dhall file shape, each citing the owning sprint.
- `legacy-tracking-for-deletion.md` enqueued `Pending Removal` rows for the pre-doctrine
  residue corresponding to each audit finding, with the owning sprint named in every
  row; those rows have now moved to `Completed`.
- `README.md` and `00-overview.md` updated the Phase `1` sprint-range strings (`Sprints
  1.6–1.23` → `Sprints 1.6–1.26`) and added Sprint 0.3 to the historical phase entry for
  Phase `0`, and add a narrative paragraph naming the audit.

### Validation

1. `prodbox dev check` passes after all Sprint 0.3 documentation edits.
2. Each new sprint block (0.3, 1.24, 1.25, 1.26) follows the rule H sprint format
   (Status / Implementation / Docs to update / Objective / Deliverables / Validation).
3. Each new sprint cites the [the engineering doctrine docs](../documents/engineering/README.md) section it
   implements by section heading, per standards rule L.
4. A manual walk of the 11 audit findings against the updated plan suite shows every
   finding resolved to either a named sprint deliverable or an explicit doctrine-aware
   deferral.
5. Mermaid render pass (standards rule K) is a no-op — Sprint 0.3 introduces no
   diagrams.

### Remaining Work

None.

## Sprint 0.4: Round-3 Doctrine Adoption Closure ✅

**Status**: Done (with May 24, 2026 supersession notes). The Sprint 2.11 extensions that
bound the forbid-fsnotify/inotify/mtime rule and the SIGHUP "TBQueue () worker is the
only sanctioned trigger" wording are superseded by Sprint 0.8 (pure-Dhall config doctrine
adoption); under the new doctrine the daemon's reload trigger is a file watcher per
[config_doctrine.md §7](../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger).
The Sprint 2.12 extension that bound "daemon log level refreshed from `LiveConfig` on
every hot reload" stands semantically — only the trigger label changes from "SIGHUP
reload" to "file-watch reload." Every other Sprint 0.4 deliverable stands.
**Implementation**: `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`,
`DEVELOPMENT_PLAN/phase-2-gateway-dns.md`,
`DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md`,
`DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: every file listed above.

### Objective

Schedule the residual [the engineering doctrine docs](../documents/engineering/README.md) items surfaced by the
May 12, 2026 round-3 doctrine-vs-plan audit so every doctrine-prescribed behavior that the
worktree did not yet honor was owned by an explicit sprint block, per
[development_plan_standards.md](development_plan_standards.md) rule L. The audit identified
fifteen doctrine prescriptions returning zero hits across the prior plan suite plus five
thinly-scheduled items; this sprint bound them through one new Phase `1` sprint (1.27) and
thirteen deliverable extensions to existing sprints.

### Deliverables

- New **Sprint 1.27: Toolchain Pin Declarations and Library-First Layout** in
  `phase-1-runtime-cli-aws-foundations.md` owns the cabal-manifest declarations
  `tested-with: ghc ==9.12.4` and `with-compiler: ghc-9.12.4`, the literal
  `Cabal 3.16.1.0` version pin, and the library-first / thin-`Main.hs` layout audit per
  [dependency_management.md#toolchain-pinning](../documents/engineering/dependency_management.md#toolchain-pinning)and
  `Project Structure` §86–115.
- Phase `1` sprint deliverable extensions (no new sprints beyond 1.27):
  - Sprint 1.6 binds the `CommandSpec` and `OptionSpec` record fields
    (`name` / `summary` / `description` / `children` / `options` / `examples` and
    `longName` / `shortName` / `metavar` / `description` / `required`) per
    [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)and binds the
    daemon-as-typed-`Command` dispatch pattern per
    [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
  - Sprint 1.8 names `callProcess`, `readCreateProcess`, and direct
    `System.Process` smart constructors as forbidden subprocess primitives in the
    `prodbox dev lint files` rules and the `.hlint.yaml` negative-space symbol set per
    [haskell_code_guide.md#subprocesses-as-typed-values](../documents/engineering/haskell_code_guide.md#subprocesses-as-typed-values).
  - Sprint 1.10 binds the thirteen minimum `fourmolu.yaml` settings (`indentation`,
    `column-limit`, `function-arrows`, `comma-style`, `import-export-style`,
    `indent-wheres`, `record-brace-space`, `newlines-between-decls`, `haddock-style`,
    `let-style`, `in-style`, `unicode`, `respectful`) per
    [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack).
  - Sprint 1.11 enumerates the canonical property-test invariants
    `decode . encode == id`, `render is deterministic`, and `parser roundtrips` as
    required `prodbox-unit` categories per
    [unit_testing_policy.md#test-categories](../documents/engineering/unit_testing_policy.md#test-categories).
  - Sprint 1.12 binds the service-error newtype inventory (`MinIOError`,
    `RedisError`, `PgError` each wrapping `ServiceError` and each carrying an
    `AsServiceError` instance) per
    [haskell_code_guide.md#capability-classes-and-service-errors](../documents/engineering/haskell_code_guide.md#capability-classes-and-service-errors).
  - Sprint 1.14 binds the daemon `AppError` record shape
    `data AppError = AppError { errorKind :: ErrorKind, errorMsg :: Text, errorCause :: Maybe SomeException }`
    per [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
  - Sprint 1.15 binds the `boundedResourceName`, `sanitizeResourceName`, and
    `hashSuffix` signatures including the DNS-1123-label and 63-character
    constraints per
    [haskell_code_guide.md#smart-constructors-for-paired-resources](../documents/engineering/haskell_code_guide.md#smart-constructors-for-paired-resources).
  - Sprint 1.21 enumerates the forbidden renderer inputs (timestamps, random IDs,
    locale-dependent ordering, terminal-width-dependent wrapping,
    environment-dependent paths) the determinism contract refuses, per
    [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts).
- Phase `2` sprint deliverable extensions (no new sprints):
  - Sprint 2.9 enumerates the structured-concurrency primitive set as the closed
    set worker loops may use: `withAsync`, `race`, `concurrently`,
    `replicateConcurrently`, per
    [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
  - Sprint 2.11 adds `fsnotify`, `inotify`, and `mtime` polling to the forbidden
    reload-trigger set per
    [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle)binds the typed Dhall
    field `schemaVersion : Natural` plus the mismatch-as-parse-failure semantic per
    `Configuration → Schema Versioning` §1530–1538, and binds the eight-step reload
    procedure step-by-step per `Configuration → Reload Procedure` §1502–1530.
  - Sprint 2.12 binds the typed field helper
    `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` and the
    convenience wrappers `logStructured`, `logDebug`, `logInfo`, `logWarn`,
    `logError` per
    [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
  - Sprint 2.13 binds the production-no-op / test-injected hook contract pattern
    per [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
  - Sprint 2.14 captures the `/healthz`, `/readyz`, and `/metrics` response shapes
    as golden tests in the `prodbox-daemon-lifecycle` stanza (200 alive for
    `/healthz`; 200 ready / 503 draining for `/readyz`; Prometheus-exposition
    format for `/metrics`) per
    [unit_testing_policy.md#test-categories](../documents/engineering/unit_testing_policy.md#test-categories)and `Long-Running Daemons in the Same
    Binary → Health Endpoints`.
- Phase `3` sprint deliverable extension (no new sprints):
  - Sprint 3.10 names `--force` and `--reinstall` flags as forbidden on the chart
    reconciler surface and names sister commands `install`, `upgrade`, `repair`,
    `force-install` as forbidden per
    [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command).
- Phase `4` sprint deliverable extension (no new sprints):
  - Sprint 4.5 applies the same forbidden-flag and sister-command discipline to the
    lifecycle reconciler: no `--force`, no `--reinstall`, no sister commands. The completed
    one-cycle `prodbox rke2 install` alias is retired after the compatibility window, and the
    name is now rejected as a forbidden sister command. Doctrine
    [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command).
- Cross-reference updates: `DEVELOPMENT_PLAN/README.md`,
  `DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`
  record the reopen, the new Sprint 1.27, and the doctrine identifiers bound by
  the round-3 extensions.
- `DEVELOPMENT_PLAN/00-overview.md` adds an explicit note that the doctrine's
  cross-language type-bridge full-file generation surface
  ([code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)) is intentionally
  empty in the supported worktree today because no non-Haskell consumer exists;
  the registry will be populated when one does. Composes with Sprint 1.23's
  existing deferral.
- `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` records that Sprint 0.4
  introduced no new pending-removal scope. The round-3 audit bindings were
  green-field plan-text additions, not deprecations; the implementation residue
  they scheduled has now closed through the downstream owning sprints.

### Validation

1. `prodbox dev check` passes after all Sprint 0.4 documentation edits.
2. A grep-audit replay against `DEVELOPMENT_PLAN/*.md` confirms every doctrine
   identifier named in this sprint's deliverables now appears at least once.
   Spot-check identifiers: `tested-with`, `with-compiler`, `Cabal 3.16.1.0`,
   `library-first`, `thin Main.hs`, `fsnotify`, `inotify`, `mtime`, `--force`,
   `--reinstall`, `force-install`, `callProcess`, `readCreateProcess`, `field ::`,
   `logStructured`, `logDebug`, `errorKind ::`, `errorMsg ::`, `errorCause ::`,
   `decode . encode`, `race`, `replicateConcurrently`, `OptionSpec`,
   `GatewayDaemonCommand`.
3. Each new sprint block (0.4, 1.27) follows the rule H sprint format
   (Status / Implementation / Docs to update / Objective / Deliverables /
   Validation).
4. Each new deliverable cites the [the engineering doctrine docs](../documents/engineering/README.md)
   section it implements by section heading, per standards rule L.
5. Mermaid render pass (standards rule K) is a no-op — Sprint 0.4 introduces no
   diagrams.

### Doctrine Sections Cited

- "Toolchain pinning" (§70–84)
- "Project Structure" → library-first layout, thin Main.hs (§86–115)
- "Automatically Generated Documentation" → `CommandSpec` / `OptionSpec` record
  shape (§283–304)
- "Long-Running Daemons in the Same Binary → Daemon as Command" (§1156–1196)
- "Long-Running Daemons in the Same Binary → Lifecycle → Structured Concurrency"
  (§1313–1324)
- "Long-Running Daemons in the Same Binary → Configuration → Reload Trigger"
  (§1491–1500)
- "Long-Running Daemons in the Same Binary → Configuration → Schema Versioning"
  (§1530–1538)
- "Long-Running Daemons in the Same Binary → Configuration → Reload Procedure"
  (§1502–1530)
- "Long-Running Daemons in the Same Binary → Logging" → typed field helpers
  (§1370–1410)
- "Long-Running Daemons in the Same Binary → Error Handling" → `AppError` record
  shape (§1300–1340)
- "Long-Running Daemons in the Same Binary → Test Hooks" → production no-op /
  test injected (§1284–1300)
- "Reconcilers → Forbidden Patterns" (§1781–1803)
- "Smart Constructors for Paired Resources" → naming-helper signatures (§565–630)
- "Capability Classes and Service Errors" → service-error newtype inventory
  (§867–890)
- "Architecture → Subprocesses as Typed Values" → forbidden primitives (§531)
- "Lint, Format, and Code-Quality Stack → Pinned fourmolu.yaml" → 12 minimum
  settings (§1834–1860)
- "Generated Artifacts → Renderer Determinism" → forbidden inputs (§459–470)
- "Test Categories → Property Tests" → invariant examples (§2179–2188)
- "Test Categories → Golden Tests" → health-endpoint response shapes (§2243)
- "Generated Artifacts → Two categories of generation → Full generation" →
  cross-language type bridges deferral (§395–400)

### Remaining Work

None.

## Sprint 0.5: `rke2 delete` Success-Summary Doctrine Scheduling ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`
**Docs to update**: every file listed above.

### Objective

Schedule the remaining `prodbox rke2 delete --yes` success-path output residue so the lifecycle
surface, cleanup ledger, and governed documentation converge on one doctrine-owned contract:
successful delete runs emit only `prodbox`'s summary lines, while hard failures retain actionable
context.

### Deliverables

- Add **Sprint 4.8: Hermetic `rke2 delete` Success Reporting** to
  `phase-4-lifecycle-canonical-paths.md` as the owning implementation sprint for the lifecycle
  follow-up. The sprint cites
  [Output Rules](../documents/engineering/streaming_doctrine.md#8-output-rules) and
  [Reconcilers: Idempotent Mutation as a Single
  Command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command).
- Reopen the top-level plan surfaces so they state the current reality: Phase `0` re-closed after
  scheduling the follow-up, Phase `4` is reopened by planned Sprint `4.8`, later phases remain
  closed on their owned surfaces, and the overall handoff is incomplete until the lifecycle-output
  follow-up lands.
- Add a `Pending Removal` ledger row for the remaining supported-path residue: benign upstream
  uninstall-script chatter can still leak on successful `prodbox rke2 delete --yes` runs even
  though the supported contract is summary-oriented cleanup reporting.
- Bind the documentation work explicitly under
  [../documents/documentation_standards.md](../documents/documentation_standards.md): when Sprint
  `4.8` lands it must update `documents/engineering/cli_command_surface.md`,
  `documents/engineering/streaming_doctrine.md`, and
  `documents/engineering/storage_lifecycle_doctrine.md` together, keep their header metadata and
  `Referenced by` backlinks aligned, and avoid introducing a competing status ledger outside
  `DEVELOPMENT_PLAN/`.

### Validation

1. `prodbox dev check` passes after the Sprint 0.5 plan edits.
2. `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
   `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
   `DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`, and
   `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` all name Sprint `4.8` consistently.
3. The new pending-removal row names Sprint `4.8` as the owner of the remaining delete-output
   residue.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/documentation_standards.md` — add the six Generated Sections elements named by the
  doctrine's "Project-level documentation standards" subsection.
- `documents/engineering/code_quality.md` — defer to the doctrine's `Lint, Format, and
  Code-Quality Stack` for the lint discipline, `Forbidden Surfaces (Negative-Space Lint)` for
  the forbidden-path registry, and `Generated Artifacts → The generated-section registry` for
  the paired check/write contract.
- `documents/engineering/unit_testing_policy.md` — defer to the doctrine's `Testing Doctrine`,
  `Test Categories`, and `Test Organization` for the tasty stanza model.
- `documents/engineering/prerequisite_doctrine.md` — defer to the doctrine's `Prerequisites as
  Typed Effects` for the registry shape and remedy-hint contract.
- `documents/engineering/cli_command_surface.md` — defer to the doctrine's `Command Topology`,
  `CommandSpec`, and `Progressive Introspection` sections, and document the `prodbox rke2 delete`
  success-summary contract once Sprint `4.8` lands.
- `documents/engineering/haskell_code_guide.md` — defer to the doctrine for GADT state machines,
  smart constructors, subprocess values, retry policy, and capability classes.
- `documents/engineering/refactoring_patterns.md` — defer to the doctrine's `Plan / Apply` and
  `Reconcilers` sections.
- `documents/engineering/effect_interpreter.md` — defer to the doctrine's
  `Subprocesses as Typed Values` and `Long-Running Daemons in the Same Binary →
  Structured concurrency` sections.
- `documents/engineering/streaming_doctrine.md` — define the lifecycle-specific rule that
  successful `prodbox rke2 delete --yes` runs emit only doctrine-owned summary lines while failure
  paths preserve actionable upstream context.
- `documents/engineering/storage_lifecycle_doctrine.md` — record the delete-side cleanup-summary
  contract and the distinction between benign host-noise suppression on success and actionable
  failure context.

Engineering docs scheduled by Sprint `0.12` (Vault secret-management doctrine + documentation
harmony):

- `documents/engineering/vault_doctrine.md` — new SSoT for Vault as the fail-closed secrets / KMS /
  PKI backend: the typed `SecretRef` model, the host-side `vault-unlock-bundle.age` bundle, Vault
  Transit envelope encryption (`prodbox-envelope-v1`), the sealed-state fail-closed invariant,
  in-cluster Vault Kubernetes auth, the config/state classification, and the red-team checklist.
- `documents/engineering/config_doctrine.md` — defer to `vault_doctrine.md` for the typed
  `SecretRef` config contract and the `test-secrets.dhall` test-only plaintext split.
- `documents/engineering/secret_derivation_doctrine.md` — defer to `vault_doctrine.md` for the
  Vault-Transit envelope over the at-rest master seed while keeping the master-seed HMAC-SHA-256
  derivation and daemon-only seed boundary intact.
- `documents/engineering/storage_lifecycle_doctrine.md` — defer to `vault_doctrine.md` for MinIO as
  a ciphertext store and the durable Vault PV preserved across cluster wipes alongside the MinIO PV.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` — defer to `vault_doctrine.md` for
  Vault deploy/unseal during reconcile and Vault PV preservation during teardown.
- `documents/engineering/envoy_gateway_edge_doctrine.md` — defer to `vault_doctrine.md` for the TLS
  private-key path and PKI material held behind Vault.
- `documents/engineering/helm_chart_platform_doctrine.md` — defer to `vault_doctrine.md` for chart
  and Keycloak secrets sourced via Vault Kubernetes auth.
- `documents/engineering/acme_provider_guide.md` — defer to `vault_doctrine.md` for the ACME EAB
  material held in Vault while keeping the single ZeroSSL issuer + S3 retain-restore intact.
- `documents/engineering/aws_admin_credentials.md` — defer to `vault_doctrine.md` for AWS
  credentials stored in Vault KV.
- `documents/engineering/cli_command_surface.md` — defer to `vault_doctrine.md` for the `prodbox
  vault` command group surface.

Governed docs touched by the Sprint `0.9`–`0.10` design-intention review (Documentation
Harmony as an enforced invariant):

- `documents/documentation_standards.md` — define the lint contract that the
  `**Generated sections**` header field, the in-file `<prodbox>:<key>:start|end` markers, and
  the `GeneratedSectionRule` registry must agree, and the relative-link integrity check (Sprint
  `0.9`); record the new generated sections introduced by Sprint `0.10`.
- `documents/engineering/pure_fp_standards.md` — soften the GADT-Indexed State Machines mandate
  to admit a flat exhaustive ADT for externally-authoritative / log-reconciled state (a
  `Disposition` projection), keeping the exhaustive-ADT and no-raw-`String` requirements
  (Sprint `0.9`; owned by Sprint `1.32`).
- `documents/engineering/haskell_code_guide.md` — rewrite Capability Classes / Service Errors to
  the argv-shaped `runMinIO` / `runRedis` / `runPg` reality, mark `HasRedis` vestigial, and keep
  the typed-`ServiceError`-classified-by-constructor and forbid-retry-of-non-retryable intents
  (Sprint `0.9`; owned by Sprint `1.30`).
- `documents/engineering/code_quality.md` — strike the bullet forbidding `fsnotify` /
  `inotify` / `getModificationTime`, since
  [config_doctrine.md §7](../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger)
  makes `fsnotify` the required reload mechanism (Sprint `0.9`); record the generated-section
  registry extensions for Sprint `0.10`.
- `documents/engineering/distributed_gateway_architecture.md` and
  `documents/engineering/tla_modelling_assumptions.md` — rewrite Orders promotion to be
  restart-based and add the single-host-degenerate-mesh topology / fault-model note (Sprint
  `0.9`; owned by Sprint `2.25`).
- `documents/engineering/aws_integration_environment_doctrine.md` — historical Sprint `0.9`
  correction assigned per-run MinIO and `aws-ses` long-lived S3. That checkpoint assignment is
  superseded by the uniform Model-B architecture (`0.14`/`7.14`) and the Sprint `4.47` authority
  clarification: main `aws-ses` state uses the retained control-plane Model-B store; S3 remains
  retained TLS/legacy-import storage.
- `documents/engineering/cli_command_surface.md` — convert the §2/§3 operator command matrix to
  a generated section sourced from `commandRegistry` (Sprint `0.10`).
- `documents/engineering/helm_chart_platform_doctrine.md` — convert the chart→edge-resource
  ownership table to a generated section (Sprint `0.10`).

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Root guidance docs (`README.md`, `AGENTS.md`, `CLAUDE.md`) link to
  [the engineering doctrine docs](../documents/engineering/README.md) as the architectural doctrine.
- The doctrine itself lists every governed-doc and plan-file consumer in its
  `**Referenced by**` line.

## Sprint 0.6: Substrate Doctrine Adoption ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/development_plan_standards.md` (adds Core Principle M),
`DEVELOPMENT_PLAN/substrates.md` (new), `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`,
`DEVELOPMENT_PLAN/phase-2-gateway-dns.md`,
`DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md`,
`DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`,
`DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md` (renamed from
`phase-5-public-host-validation.md`),
`DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md` (renamed from
`phase-7-aws-iam-quota-automation.md`),
`DEVELOPMENT_PLAN/phase-8-email-invite-auth.md` (new),
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `documents/engineering/unit_testing_policy.md`
**Docs to update**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`,
`DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Introduce the substrate doctrine into the canonical phase model so the plan reflects the
truth the codebase already implements: there is one canonical test suite (the
substrate-agnostic named-validation set in `src/Prodbox/TestValidation.hs`,
`src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/Prerequisite.hs`)
that runs against substrates rather than separate home-cluster and AWS validation surfaces.

### Deliverables

- Core Principle M (Test Suite Substrates) lands in
  `DEVELOPMENT_PLAN/development_plan_standards.md`. Principle E's canonical document
  structure is amended to include `substrates.md` and `phase-8-email-invite-auth.md`, and
  to reflect the phase-5 and phase-7 renames.
- `DEVELOPMENT_PLAN/substrates.md` is the authoritative substrate inventory with provision,
  teardown, prerequisites satisfied, suite parity status, and cross-substrate shared resources
  documented per substrate.
- `DEVELOPMENT_PLAN/00-overview.md` carries a `Test Substrates` section, and the Clean-Room
  Sequence table reframes phase-5 as the canonical test suite owner and phase-7 as the AWS
  substrate foundations owner.
- `DEVELOPMENT_PLAN/system-components.md` classifies clusters and Pulumi stacks by substrate
  and collapses the Validation Layer's substrate-split listings into one canonical test-suite
  inventory.
- `phase-5-public-host-validation.md` is renamed to `phase-5-canonical-test-suite.md` and
  rewritten so that every named validation is described as substrate-agnostic suite content
  with declared prerequisites.
- `phase-7-aws-iam-quota-automation.md` is renamed to `phase-7-aws-substrate-foundations.md`
  with AWS IAM and quota reframed as AWS-substrate foundations, plus a new sprint that brings
  the AWS substrate to canonical-suite parity with the home substrate.
- `phase-8-email-invite-auth.md` is added for the operator-invited email authentication path
  via Keycloak + AWS SES, including the `ValidationKeycloakInvite` suite content and the
  shared cross-substrate SES infrastructure.
- `phase-4-lifecycle-canonical-paths.md` is updated to drop the "AWS validation doctrine"
  framing and to describe AWS-touching content as AWS-substrate lifecycle (provision +
  teardown via Pulumi).
- the engineering doctrine docs and `documents/engineering/unit_testing_policy.md` are updated to
  cite the new substrate doctrine and to use the renamed phase paths.

### Validation

1. `prodbox dev check`.
2. Doctrine integrity grep across `DEVELOPMENT_PLAN/`: no remaining "AWS validation",
   "home-cluster validation", or "named validation surface" wording outside
   `legacy-tracking-for-deletion.md` (or with deliberate justification).
3. Cross-reference integrity grep: no inbound reference to the old phase paths
   `phase-5-public-host-validation.md` or `phase-7-aws-iam-quota-automation.md` survives in
   any file under the repository.

### Remaining Work

None.

### Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/unit_testing_policy.md` — cross-reference the substrate doctrine
  and reword any column that lists "AWS, DNS, gateway, chart, lifecycle, and public-edge
  proofs" so it lists the canonical-suite validation names instead of the substrates they
  touch.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- the engineering doctrine docs cross-references the renamed `phase-5-canonical-test-suite.md` and
  `phase-7-aws-substrate-foundations.md` paths plus the new `phase-8-email-invite-auth.md`
  and `substrates.md` files.

## Sprint 0.7: LLM / Automation Guardrails on Interactive Commands ✅

**Status**: Done (May 20, 2026)
**Implementation**: new `src/Prodbox/CLI/Interactive.hs`
(`InteractiveGuard`, `requireInteractiveTty`, `renderNonTtyError`,
per-command guard values `awsSetupGuard`, `awsTeardownGuard`,
`awsCheckQuotasGuard`, `awsRequestQuotasGuard`, `configSetupGuard`,
`chartsDeleteGuard`, and the test-only env-var name
`allowNonTtyInteractiveEnvVar = "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"`);
`src/Prodbox/Aws.hs` (`requireInteractiveTty` wired at the head of every
`interactive*Input` function and at the start of `runAwsCommand` /
`runInteractiveConfigSetupWithPlan`'s `try @SomeException` block — the
new `fromException @ExitCode` re-throw fixes the "exit code displayed
as crash" bug that surfaced once `requireInteractiveTty` started
calling `exitWith`); `src/Prodbox/CLI/Charts.hs::promptForDelete`
(`requireInteractiveTty` ahead of the `[y/N]` prompt);
`test/integration/CliSuite.hs` (`fakeAwsEnvironment` /
`fakeAwsHarnessEnvironment` helpers set
`PRODBOX_ALLOW_NON_TTY_INTERACTIVE=1` so the existing interactive-flow
integration tests still drive the prompts with piped stdin);
`test/unit/Main.hs::"interactive non-TTY guard"` describe block (6
guard rendering tests + 1 env-var-name assertion);
`documents/engineering/cli_command_surface.md` (new "§ 3A Interactive
vs Non-Interactive Surfaces" section);
`documents/engineering/aws_integration_environment_doctrine.md` (one-
line cross-reference); `CLAUDE.md` and `AGENTS.md` (new
"Command Selection: Automation vs Operator-Interactive" table).
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`CLAUDE.md`, `AGENTS.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Close a chronic LLM / CI failure mode where automation agents would
run `prodbox aws setup` (or the other operator-interactive commands),
hit the credential prompt, and report the prompt as a blocker
instead of switching to `prodbox test all --substrate aws` or the
targeted `prodbox test integration ... --substrate aws` command.
Every operator-interactive entry point must now refuse to run when
stdin is not a TTY and emit an explicit guidance message naming the
automation equivalent.

### Deliverables

- New module `src/Prodbox/CLI/Interactive.hs` with the
  `InteractiveGuard` record, `requireInteractiveTty` runtime check,
  `renderNonTtyError` message builder, per-command guard values, and
  the test-only env-var name. Production agents must never set the
  env var; only `fakeAwsEnvironment` / `fakeAwsHarnessEnvironment` in
  the integration test helpers are sanctioned to.
- `requireInteractiveTty` called at the head of every
  `interactive*Input` function in `src/Prodbox/Aws.hs` covering
  `config setup`, `aws setup`, `aws teardown`, `aws check-quotas`,
  `aws request-quotas`, and at the head of `promptForDelete` in
  `src/Prodbox/CLI/Charts.hs`.
- The `try @SomeException` blocks in `runAwsCommand` and
  `runInteractiveConfigSetupWithPlan` updated to re-throw `ExitCode`
  exceptions via `fromException @ExitCode`, so the guard's own
  `exitWith` is not double-reported as `ExitFailure 1` after the
  guard's stderr message has already been written.
- `documents/engineering/cli_command_surface.md` "§ 3A — Interactive
  vs Non-Interactive Surfaces" documents the contract, the per-command
  automation equivalents, and the `PRODBOX_ALLOW_NON_TTY_INTERACTIVE`
  test-only escape.
- A new "Command Selection: Automation vs Operator-Interactive"
  command-mapping table in `CLAUDE.md` and `AGENTS.md` so future
  agents pick the right surface without first running the wrong one.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` exit 0 (6 new guard rendering tests + 1
   env-var-name assertion under the `interactive non-TTY guard`
   describe block).
3. `prodbox test integration cli` exit 0 (all interactive-flow tests
   pass because the fake-env helpers now set the bypass env var).

### Remaining Work

None. The legacy-tracking ledger row records the closure.

## Sprint 0.8: Pure-Dhall Config Doctrine Adoption ✅

**Status**: Done (May 24, 2026 — doctrine SSoT
[config_doctrine.md](../documents/engineering/config_doctrine.md) created, governed
engineering docs and root docs revised to defer to it, plan suite updated; the four
validation gates exit 0 — `prodbox dev lint docs`, `prodbox dev docs check`, `prodbox dev check`,
`prodbox test unit` 533/533. The code implementation lands in Phase 1 Sprint 1.28 and
Phase 2 Sprints 2.20/2.21/2.22 and Phase 3 Sprint 3.14.)
**Implementation**: new `documents/engineering/config_doctrine.md`;
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/cli_command_surface.md`,
`documents/engineering/dependency_management.md`,
`documents/engineering/haskell_code_guide.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/secret_derivation_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/README.md`, `documents/documentation_standards.md`,
`README.md`, `CLAUDE.md`, `AGENTS.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`,
`DEVELOPMENT_PLAN/phase-2-gateway-dns.md`,
`DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md`,
`DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`
**Docs to update**: every file listed above.

### Objective

Consolidate `prodbox`'s configuration sourcing to a single doctrine — every binary
instance takes its config from one Dhall file passed via `--config <path>`, decoded
in-process by the native Haskell `dhall` library, with no env-var precedence ladder, no
JSON projection, and no SIGHUP-driven reload. The new SSoT
[config_doctrine.md](../documents/engineering/config_doctrine.md) holds the authoritative
contract; this sprint adopts that SSoT into every governed doc and the development plan,
per [development_plan_standards.md §L](development_plan_standards.md). The code
implementation of the new doctrine is scheduled in Phase 1 (Sprint 1.28), Phase 2
(Sprints 2.20, 2.21, 2.22), and Phase 3 (Sprint 3.14).

### Deliverables

- New `documents/engineering/config_doctrine.md` SSoT covering: single Dhall surface per
  binary, canonical paths (host repo-root, in-cluster mount), native `dhall`-library
  decoding, Dhall imports for credentials and Orders, cluster mount contract
  (ConfigMaps for non-credential content, Secrets for credentials), file-watch reload
  trigger, BootConfig-vs-LiveConfig classification with drain-and-exit on boot-field
  changes, and the forbidden-surfaces list.
- Revision passes on every governed engineering doc named under **Implementation**, each
  deferring config-sourcing language to the new SSoT and removing contradicting passages
  (SIGHUP-only reload, forbid-fsnotify, `PRODBOX_*` env-var precedence ladder, env-var-
  sourced daemon credentials, JSON-rendered daemon config, `--log-level` /
  `--port` runtime override flags).
- Revision passes on `README.md`, `CLAUDE.md`, and `AGENTS.md` to point operators and
  agents at the new SSoT and remove env-var precedence claims.
- Revision passes on `DEVELOPMENT_PLAN/README.md` (the then-current closure and phase-record
  updates for Phases 0/1/2/3), `00-overview.md` (BootConfig /
  LiveConfig and daemon CLI plumbing paragraphs), `system-components.md` (rows for
  BootConfig / LiveConfig, daemon CLI, prescribed daemon config shape, reload trigger,
  reload procedure), and `legacy-tracking-for-deletion.md` (new Pending Removal rows
  per the implementing sprints).
- Revision notes on Sprint 0.3 and Sprint 0.4 calling out the superseded forbid-fsnotify
  and SIGHUP-trigger extensions; both sprints stay `Done` on their non-superseded
  surfaces per `development_plan_standards.md §A`.

### Validation

1. `prodbox dev lint docs` exit 0 (proves Generated Sections metadata stays consistent with
   markers across every governed doc).
2. `prodbox dev docs check` exit 0 (proves CLI-doc generated artifacts stay consistent — this
   sprint touches no generated content).
3. `prodbox dev check` exit 0 (no code changes; passes by no-op).
4. `prodbox test unit` 533/533 (no test text changes expected; goldens unaffected).
5. Manual narrative check: read `DEVELOPMENT_PLAN/00-overview.md` and the revised phase
   docs start-to-finish; the rewrite reads as a coherent buildout, no phase contradicts
   another, per `development_plan_standards.md §A`.

### Remaining Work

- The code implementation of the new doctrine lands in the Phase 1/2/3 sprints named in
  Objective. Sprint 0.8 closes when its doc revisions are complete and the four lint /
  build / test gates exit 0; the live exercise of the file-watch reload trigger is the
  closure gate for Sprint 2.21, not Sprint 0.8.

## Sprint 0.9: Documentation Harmony as an Enforced Invariant ✅

**Status**: Done (2026-06-09). The five doctrine corrections and the repo-wide
`**Generated sections**` header sweep landed, and the lint-enforcement code shipped: the
header↔markers↔registry reconciler (`checkGeneratedSectionsHarmony`) and the governed-doc
relative-link check (`checkGovernedDocRelativeLinks`) are wired into `runGeneratedArtifactLint`,
so `prodbox dev lint docs` / `docs check` / `check-code` fail closed on any header/marker/registry
disagreement or dangling relative link. The sha256 Dhall-freeze decision resolved to **strike**
the over-claim (see Deliverables). Validation green: `check-code` 0, `test unit` 732/732,
`lint docs` 0, `docs check` 0.
**Implementation**: `src/Prodbox/CheckCode.hs` (`checkGeneratedSectionsHarmony`,
`checkGovernedDocRelativeLinks`, and their fenced-code-aware pure helpers, wired into
`runGeneratedArtifactLint`), `test/unit/Main.hs` (36 pure-helper cases);
`documents/engineering/pure_fp_standards.md`,
`documents/engineering/haskell_code_guide.md`,
`documents/engineering/code_quality.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/tla_modelling_assumptions.md`,
`documents/engineering/aws_integration_environment_doctrine.md`
**Docs to update**: `documents/engineering/pure_fp_standards.md`,
`documents/engineering/haskell_code_guide.md`,
`documents/engineering/code_quality.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/tla_modelling_assumptions.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/documentation_standards.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Make Documentation Harmony — every governed doc agreeing with live code and with the other
governed docs — an invariant the lint stack enforces, rather than a property re-established
by periodic audits. The design-intention review found five doctrine statements that contradict
the live code or a sibling doctrine; the doc is wrong in each case, so this sprint repairs the
prose to match the code's target shape and schedules the lint that will keep them aligned. It
also closes the repo-wide gap where governed docs omit the
[documentation_standards.md](../documents/documentation_standards.md) `**Generated sections**`
header field.

### Deliverables

- **Five doctrine corrections** (the doc, not the code, is stale):
  - `documents/engineering/pure_fp_standards.md` (GADT-Indexed State Machines + the
    Forbidden list) softens the GADT mandate to "GADTs for authoritative in-process
    transitions; externally-authoritative / log-reconciled state (the then-current gateway
    ownership fold over the now-superseded append-only commit log was the motivating example) may use a flat
    exhaustive ADT", while keeping the exhaustive-ADT and no-raw-`String` requirements.
    Owned by Sprint `1.32`.
  - `documents/engineering/haskell_code_guide.md` (Capability Classes / Service Errors)
    rewrites the capability classes to the argv-shaped reality
    `runMinIO` / `runRedis` / `runPg :: [String] -> m (Either E ProcessOutput)`, marks
    `HasRedis` vestigial (zero `src` callers), and keeps — as the target the code moves
    to — the typed-`ServiceError`-classified-by-constructor intent and the
    forbid-retry-of-non-retryable rule, forbidding a hand-built `ServiceError` with a
    literal `retryable` `Bool`. Owned by Sprint `1.30`.
  - `documents/engineering/code_quality.md` (the daemon reload-polling guardrail) strikes
    the bullet listing `fsnotify` / `inotify` / `getModificationTime` as forbidden:
    [config_doctrine.md §7](../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger),
    the live code, and `.hlint.yaml` together make `fsnotify` the *required* reload
    mechanism. Doc-only fix landing under this sprint.
  - `documents/engineering/distributed_gateway_architecture.md` §7.5 and
    `documents/engineering/tla_modelling_assumptions.md` rewrite Orders promotion to be
    restart-based (already defined by config_doctrine §8 step 4): `stateOrdersVersionUtc`
    never advances in-process, the refuse-to-reclaim-while-behind gate is kept, and a
    topology / fault-model note records that home is a three-logical-peer mesh on one physical
    host under shared fate, while independent-host tolerance is an AWS / future-multi-host capability.
    Owned by Sprint `2.25`.
  - Historical `documents/engineering/aws_integration_environment_doctrine.md` §4.5 assigned
    per-run state to MinIO and `aws-ses` state to long-lived S3. Superseded by Sprint `0.14`/`7.14`
    Model-B uniformity and Sprint `4.47`: the retained home/control-plane Model-B store owns the
    main `aws-ses` checkpoint; S3 is TLS/legacy-import storage.
- **Repo-wide `**Generated sections**` header sweep**: every governed doc missing the
  field gains `**Generated sections**: none` (or its real marker keys) per
  [documentation_standards.md](../documents/documentation_standards.md).
- **Lint enforcement (Remaining Work)**: `runGeneratedArtifactLint` gains a
  header↔markers↔registry reconciler (the `**Generated sections**` field, the in-file
  `<prodbox>:<key>:start|end` markers, and the `GeneratedSectionRule` registry must agree)
  and a relative-link check (every relative `[text](path#anchor)` link in a governed doc
  resolves to an existing file and anchor).
- **sha256 Dhall-freeze decision — struck.** The only committed local import is
  `prodbox-config.dhall` → `./prodbox-config-types.dhall`, a co-edited sibling; cryptographic
  freezing of a co-edited sibling adds re-freeze friction with no integrity benefit, and
  `check-code` never enforced it. `documentation_standards.md` §6 is reframed (sha256 freezes
  apply to any future remote/untrusted committed import; the sole current local sibling import
  is intentionally not frozen) and `legacy-tracking-for-deletion.md` records the over-claim
  correction. No freeze check is implemented.

### Validation

1. `prodbox dev lint docs` exit 0 after the header sweep (proves `**Generated sections**`
   metadata stays consistent with markers across every governed doc).
2. `prodbox dev docs check` exit 0 (this sprint's doc edits touch no generated content).
3. `prodbox dev check` exit 0 — by no-op for the doc-only part; once the reconciler and
   relative-link check land, `check-code` fails closed on any header/marker/registry
   disagreement or dangling relative link.
4. A grep replay confirms the five corrected statements no longer contradict
   `config_doctrine.md`, the live code, or `.hlint.yaml`.

### Remaining Work

None — closed 2026-06-09. The reconciler + relative-link check are implemented and wired, and
the sha256 decision is resolved (struck). Broken governed-doc links the new check surfaced were
fixed in the same change (the `phase-8-email-invite-auth.md` `../substrates.md` over-prefix and
the over-prefixed `aws_integration_environment_doctrine.md` link).

## Sprint 0.10: Generate Drift-Prone Tables from Typed Registries ✅

**Status**: Done (2026-06-09). Two of the three drift-prone tables
are now generated from typed registries: the §2/§3 command matrix from `commandRegistry` (Sprint
`1.29`: `command-surface-toplevel`/`command-surface-matrix`) and the registry-name↔CLI-command table
that composes with the `StackDescriptor` record (Sprint `4.27`: `stack-command-surface` in
`substrates.md`). The third — the
**chart→edge-resource ownership table** — was deliberately **not** generated, per the design
guardrail (generate only a faithful projection of a typed value, with no new hand-authored
annotation): `PublicEdgeRoute` has no owning-chart field, the shared Gateway / listener-cert /
port-80-redirect resources are not routes at all, `/minio` is applied imperatively
(`Rke2.hs::ensureAdminPublicEdgeRoutes`), and the `/auth` + Gateway + cert ownership is a deployment
fact the keycloak chart owns (reattributed editorially by Sprint `7.13`). Generating it would have
required a parallel hand-authored annotation — relocating drift, not removing it — so it stays
editorial doctrine; an `envoy_gateway_edge_doctrine.md §4` note records this with the evidence.
Validation green: `check-code` 0, `test unit` 0, `docs generate`→`docs check` 0, `lint docs` 0.
**Implementation**: `src/Prodbox/CheckCode.hs` /
`src/Prodbox/CLI/Docs.hs` (extend the `GeneratedSectionRule` registry),
`documents/engineering/cli_command_surface.md`,
`documents/engineering/helm_chart_platform_doctrine.md`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/documentation_standards.md`

### Objective

Eliminate the recurring drift between the hand-maintained reference tables and the typed
sources they describe by generating those tables from the registries directly, extending
the generated-section machinery established by the doctrine's `Generated Artifacts` contract.

### Deliverables

- The `cli_command_surface.md` §2/§3 operator command matrix is generated from
  `commandRegistry` (depends on the positional-args `CommandSpec` field added by Sprint
  `1.29`).
- The chart→edge-resource ownership table is **not** generated — per the design guardrail it is
  not a faithful projection of a typed source (`PublicEdgeRoute` has no owning-chart field; the
  shared Gateway / cert / `/auth` ownership is a deployment fact, not a route), so generating it
  would relocate drift into a hand-authored annotation. It stays editorial doctrine (owned by
  Sprint `7.13`); an `envoy_gateway_edge_doctrine.md §4` note records the decision + evidence.
- The registry-name↔CLI-verb list is generated from the `StackDescriptor` SSoT record
  introduced by Sprint `4.27` (the `stack-command-surface` section in `substrates.md`).

### Validation

1. `prodbox dev docs generate` then `prodbox dev docs check` exit 0 — the generated matrix,
   ownership table, and registry-name↔verb list round-trip with the typed registries.
2. `prodbox dev lint docs` exit 0 — the new generated sections carry matching
   `**Generated sections**` header keys and `<prodbox>:<key>:start|end` markers.
3. `prodbox dev check` exit 0.

### Remaining Work

None — closed 2026-06-09 after Sprints `1.29` and `4.27` landed the two generatable tables and the
chart→edge ownership table was (correctly) left editorial per the guardrail.

## Sprint 0.12: Vault Secret-Management Doctrine and Documentation Harmony ✅

**Status**: Done
**Implementation**: `documents/engineering/vault_doctrine.md`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/README.md`, `config_doctrine.md`, `secret_derivation_doctrine.md`, `storage_lifecycle_doctrine.md`, `lifecycle_reconciliation_doctrine.md`, `envoy_gateway_edge_doctrine.md`, `helm_chart_platform_doctrine.md`, `acme_provider_guide.md`, `aws_admin_credentials.md`, `cli_command_surface.md`

### Objective

Establish the SSoT doctrine for Vault as the fail-closed secrets / KMS / PKI backend and bring the
governed documentation set into harmony with it, so the per-surface adoption sprints (`1.35`–`8.9`)
cite one authoritative source. Vault is documented as an encryption-at-rest and sealed-state
authority layer added *beneath* the existing secret model — it extends, and does not reverse, the
master-seed derivation model, the single-Dhall contract, the retained-PV model, and the single
ZeroSSL issuer.

### Deliverables

- `documents/engineering/vault_doctrine.md` created as the authoritative source for the SecretRef
  model, the host-side unlock bundle, Vault Transit envelope encryption, the sealed-state
  invariant, in-cluster Vault Kubernetes auth, the config/state classification, and the red-team
  checklist.
- The engineering index (`documents/engineering/README.md`) gains a `vault_doctrine.md` row and a
  Secrets-and-Vault quick-navigation block.
- `config_doctrine.md`, `secret_derivation_doctrine.md`, `storage_lifecycle_doctrine.md`,
  `lifecycle_reconciliation_doctrine.md`, `envoy_gateway_edge_doctrine.md`,
  `helm_chart_platform_doctrine.md`, `acme_provider_guide.md`, `aws_admin_credentials.md`, and
  `cli_command_surface.md` defer to `vault_doctrine.md` and carry the bidirectional cross-reference.
- The secret-classification model (public / sensitive-topology / secret-material) is documented in
  `vault_doctrine.md` §13 and referenced from the secret and storage docs.

### Validation

- `prodbox dev lint docs` exit 0 and `prodbox dev docs check` exit 0 (header↔markers↔registry and
  relative-link discipline) — verified 2026-06-11.
- `prodbox dev check` exit 0 (policy + Fourmolu + HLint + warning-clean build) and
  `prodbox test unit` 823/823 — the governed doc set validates; the same run also gated the
  Sprint `3.17` tmpfs seed-scratch increment (see Phase 3).
- Every governed doc's `**Referenced by**` header and cross-reference list agree (bidirectional
  link discipline). **Falsified and superseded by Sprint `0.21` (2026-08-05)** — a mechanical
  inversion across all 62 governed docs measured 53 stale and 660 missing entries, so this
  criterion was never satisfied on any revision. The field is struck; the reverse edge is now
  recovered by search.

### Remaining Work

- None — closed 2026-06-11 (all gates green).

## Sprint 0.13: Vault-Root Finalization and Cluster-Federation Doctrine Harmony ✅

**Status**: Done (2026-06-14)
**Implementation**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/cluster_federation_doctrine.md` (new),
`documents/engineering/config_doctrine.md`,
`documents/engineering/secret_derivation_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/acme_provider_guide.md`,
`documents/engineering/aws_admin_credentials.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/README.md`, repo-root `README.md` and `CLAUDE.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/substrates.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, and the phase files;
repo-root `VAULT_REFACTOR.md` deleted (folded into the doctrine set)
**Docs to update**: every file listed above.

### Objective

Finalize the secrets architecture in doctrine: Vault is the sole, fail-closed secrets / KMS / PKI
root for the entire prodbox stack, with no transitional or bridge pattern. This **supersedes** the
Sprint `0.12` framing that Vault "extends, and does not reverse, the master-seed derivation model":
the master-seed HMAC derivation model is **retired**, not wrapped; `SecretRef.FileSecret` and
Secret-mounted plaintext Dhall fragments are **removed**, not bridged; a sealed (or
unreachable / uninitialized) Vault **bricks** the cluster — there is no degraded mode that leaks.
This sprint also introduces cluster federation as a Vault transit-seal trust tree: a root cluster
unsealed by the operator and zero or more child clusters that auto-unseal against their parent's
Vault, with the parent custodying each child's init keys and the fail-closed brick cascading down
the tree. The change brings the governed documentation set into harmony with that end state so the
per-surface adoption sprints (`1.35`–`8.9`, plus the new `1.38`, `2.26`, `3.19`, `3.20`, `4.32`)
cite one authoritative source. Like Sprint `0.12`, this is a docs / plan-only sprint; the code
adoption lands in the cited implementation sprints.

### Deliverables

- `documents/engineering/vault_doctrine.md` rewritten as the finalized statement of the Vault-root
  model: the `SecretRef` union with **no** `FileSecret` arm (`Vault` / `TransitKey` / `Prompt` /
  `TestPlaintext`), the derivation model stated as retired with Vault KV as the sole store, the
  cluster-federation transit-seal hierarchy summarized with a link to the new federation doctrine,
  and the substance of the repo-root `VAULT_REFACTOR.md` proposal folded in. Honest
  "intended structure scheduled under Sprint X" markers are kept using the new sprint set, per
  [development_plan_standards.md](development_plan_standards.md) rule L.
- New `documents/engineering/cluster_federation_doctrine.md` SSoT covering the root / child trust
  tree, Vault transit-seal auto-unseal, parent custody of child init keys, downstream-cluster
  metadata as secret data, the root-token config-write authority, the fail-closed unseal cascade,
  and the unencrypted-basics bootstrap surface. It is added to the engineering index
  (`documents/engineering/README.md`) and cross-links `vault_doctrine.md`, `config_doctrine.md`,
  `distributed_gateway_architecture.md`, and `storage_lifecycle_doctrine.md`.
- `config_doctrine.md` rewritten so the in-force cluster configuration is the
  Vault-Transit-enveloped MinIO object (the SSoT), the filesystem `prodbox-config.dhall` is a
  seed / propose input only, the unencrypted-basics local surface is described, and root-cluster
  config writes require the root Vault token; the §6 Secret-mounted Dhall mount-contract rows and
  the §5 `as Text` credential-import example are removed in favor of Vault Kubernetes auth.
- `secret_derivation_doctrine.md` retitled to a Vault-backed secret-management framing (filename
  retained only for link stability); the master-seed / HMAC mechanism content replaced by the
  every-secret-is-a-Vault-object model, with the inventory table mapping each secret to its Vault
  KV / PKI / Transit path, owning Vault policy, and consuming service account.
- `helm_chart_platform_doctrine.md`, `storage_lifecycle_doctrine.md`, `acme_provider_guide.md`,
  `aws_admin_credentials.md`, and `aws_integration_environment_doctrine.md` rewritten to the
  finalized model: chart / Keycloak secrets via Vault Kubernetes auth only; the Vault PV durable on
  the init-once / unseal-on-rebuild contract; ACME EAB material and TLS key material Vault-protected
  with Vault PKI as the cert authority; prodbox-created AWS identities in Vault KV and the elevated
  admin credential prompted-used-discarded.
- Repo-root `README.md` and `CLAUDE.md` paragraphs updated to drop the "daemon-only raw master
  seed" and "credentials imported from a sibling Secret-mounted Dhall fragment" claims and state
  the Vault-root model.
- The plan suite — `DEVELOPMENT_PLAN/README.md`, `00-overview.md`, `system-components.md`,
  `substrates.md`, `legacy-tracking-for-deletion.md`, and the reopened phase files — harmonized to
  the finalized model: the existing Vault sprints (`1.35`–`8.9`) reframed to own the finalized
  end state, the new sprints (`0.13`, `1.38`, `2.26`, `3.19`, `3.20`, `4.32`) added, Phase `2`
  reopened for cluster-federation custody, and the legacy ledger repointed so the Vault rows own
  complete removal (no bridge) and the master-seed derivation model is itself slated for removal.
- Repo-root `VAULT_REFACTOR.md` deleted; its substance lives in `vault_doctrine.md` and
  `cluster_federation_doctrine.md`, and the legacy ledger records the deletion as owned here.

### Validation

1. `prodbox dev lint docs` exit 0 (header↔markers↔registry and relative-link discipline across
   every governed doc, including the new `cluster_federation_doctrine.md`).
2. `prodbox dev docs check` exit 0 (this sprint's doc edits touch no generated content).
3. `prodbox dev check` exit 0 — by no-op for the docs-only part.
4. Every governed doc's `**Referenced by**` header and cross-reference list agree (bidirectional
   link discipline), and no inbound reference to the deleted `VAULT_REFACTOR.md` survives.
   **The back-link half is falsified and superseded by Sprint `0.21` (2026-08-05)** — it was never
   satisfied on any revision. The `VAULT_REFACTOR.md` half stands.
5. A grep replay confirms no governed doc still frames the Vault-root model or the
   derivation-retirement as future-optional, and the `FileSecret` arm no longer appears in any
   `SecretRef` union mention.

### Remaining Work

- None — the doc and plan rewrites land in this change. The code adoption of the finalized model
  lands in the cited implementation sprints (`1.35`–`1.38`, `3.17`–`3.20`, `4.29`–`4.32`, `5.8`,
  `7.14`–`7.15`, `8.9`, and the federation surface under `2.26`); each closes on its own owned
  surface when its validation gates pass.

## Sprint 0.14: Model-B Pulumi/MinIO and Whole-System Sealed-State Doctrine Harmony ✅

**Status**: Done (2026-06-15)
**Implementation**: the rewritten doctrine docs —
`documents/engineering/vault_doctrine.md` (§9 promoted to the full Model-B object-store spec,
§10 rewritten to the decrypt-to-scratch Pulumi interposition with Pulumi's secrets provider
dropped, the new "Whole-system zero-child-info" subsection, and the §13 / §14 / §19
classification / logging / red-team extensions),
`documents/engineering/config_doctrine.md` (§1a in-force config flows through the §9
object-store), `documents/engineering/cluster_federation_doctrine.md` (§3–§4 downstream
identity custodied in Vault KV, opaque child namespaces, no child name on a sealed log path),
`documents/engineering/helm_chart_platform_doctrine.md` (§6 opaque-named MinIO hostPath),
`documents/engineering/storage_lifecycle_doctrine.md` (the `.data/prodbox/minio/0` hostPath
holds opaque-named ciphertext only), `documents/engineering/streaming_doctrine.md`
(no-name-in-logs + no exists-vs-absent oracle cross-link); the legacy-ledger repoint
(`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`); and the plan-suite harmony —
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, and the reframed / new implementation sprints
(`1.37`, `4.30`, `4.33`, `7.14`); repo-root `README.md` and `CLAUDE.md`
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/config_doctrine.md`,
`documents/engineering/cluster_federation_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/streaming_doctrine.md`, repo-root `README.md` and `CLAUDE.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, and the reframed phase files
(`phase-1-runtime-cli-aws-foundations.md`, `phase-4-lifecycle-canonical-paths.md`,
`phase-7-aws-substrate-foundations.md`)

### Objective

Finalize how `prodbox` encrypts MinIO-stored state and Pulumi backend state under the
Vault-root model, and bring the governed documentation set into harmony with that decision.
The governing invariant: when the parent cluster's Vault is sealed, it must be impossible to
extract any information about its children — whether it has any, how many, where, or what —
down to object / key names like `aws` / `aws-eks`. The settled answer is **Model B**: a
`prodbox` application-level Vault-Transit envelope per object (not MinIO bucket SSE), which is
Vault-native, AAD-bound, and keeps naming / index / padding in the same trusted layer. Pulumi's
own secrets provider is **dropped** — the `prodbox` envelope is the encryption. The invariant is
an existence / metadata property, so the scope is the **whole system** — MinIO objects, the host
disk, Kubernetes objects, and logs / output (including the exists-vs-`NoSuchKey` oracle) — not a
MinIO-only content control. This **refines** the 2026-06-14 Vault-root finalization; it does not
reverse it, and reopens no new phase. Like Sprints `0.12` and `0.13`, this is a docs / plan-only
sprint; the code adoption lands in the cited implementation sprints.

### Deliverables

- `documents/engineering/vault_doctrine.md` rewritten as the SSoT for Model B and the
  whole-system invariant:
  - **§9 (MinIO as a ciphertext store)** promoted from the opaque-ID sketch to the full
    **Model-B object-store** spec — every `prodbox`-owned object flows through one
    application-level layer that envelopes via Vault Transit, names objects
    `objects/<vault-keyed-HMAC>.enc` under one flat prefix, keeps a Vault-encrypted
    `indexes/*.enc` id↔logical map, **hashes the stored AAD** (`prodbox-envelope-v2`), and
    **decoy-pads to a constant object count** plus size buckets. The on-disk consequence is
    stated: the hostPath PV (`.data/prodbox/minio/0`) holds only opaque-named ciphertext. All
    `prodbox`-owned secret-bearing state lives in **one generically-named bucket** (the
    role-revealing `prodbox` + `prodbox-test-pulumi-backends` names retired), and the
    object-store is **shared by the host CLI and the in-cluster gateway daemon** — one
    envelope / naming / index discipline, each accessor binding its own Vault-auth `DekCipher`
    (host root token; daemon Kubernetes auth over the in-cluster MinIO Service DNS).
  - **§10 (Pulumi backend under Vault)** rewritten to commit to the **decrypt-to-scratch
    interposition** as the mechanism — each op hydrates the stack into a RAM-tmpfs `file://`
    backend, runs `pulumi`, then re-envelopes and opaque-names back through the §9 object-store,
    so Pulumi never touches MinIO and the PV only ever holds opaque ciphertext. **Pulumi's own
    secrets provider is dropped**; the Option-A/B/C ladder and the Vault-derived-passphrase
    sequencing are removed; the two layers are stated explicitly (AWS input creds in Vault KV +
    the readiness gate; the whole checkpoint enveloped + opaque-named through §9); and the
    long-lived-SSE carve-out is removed — per-run and `aws-ses` are treated uniformly.
  - A new **"Whole-system zero-child-info"** subsection enumerates the four covered surfaces —
    MinIO objects, the host disk, Kubernetes objects, and logs / output (including the
    exists-vs-`NoSuchKey` oracle).
  - The **§13 classification table** "Sensitive topology" row adds object names / counts +
    Pulumi stack identities; **§14 logging** and the **§19 red-team checklist** add the
    opaque-name layout, constant count, no exists-vs-absent oracle, host-disk-walk-reveals-only-
    opaque-ciphertext, and k8s-leaks-no-child-name checks.
- `config_doctrine.md` §1a notes the in-force config flows through the §9 object-store (an opaque
  `objects/<id>.enc`, not the literal `in-force-config` key).
- `cluster_federation_doctrine.md` §3–§4 state that downstream kubeconfig / identity is custodied
  in the parent's Vault KV (`secret/clusters/<child-id>/*`), never a k8s Secret; child-named
  namespaces use opaque IDs; logs never emit a child name on a sealed path.
- `helm_chart_platform_doctrine.md` §6 and `storage_lifecycle_doctrine.md` state the
  `.data/prodbox/minio/0` hostPath holds opaque-named ciphertext only.
- `streaming_doctrine.md` cross-links the no-name-in-logs and no exists-vs-absent oracle rules.
- Repo-root `README.md` and `CLAUDE.md` harmonize the MinIO / Pulumi / Vault summary paragraphs to
  Model B + uniform envelope, dropping any "long-lived SSE" wording.
- The plan suite — `DEVELOPMENT_PLAN/README.md` (new dated 2026-06-15 historical closure entry
  framed as a refinement that reopens no new phase), `00-overview.md`, `system-components.md`
  (the "Pulumi backend state" row → enveloped + opaque-named via the object-store; MinIO objects
  opaque-named), and `legacy-tracking-for-deletion.md` (a 2026-06-15 Ledger Status paragraph and
  the repointed / added Pending Removal rows) — harmonized to Model B, and the implementation
  sprints reframed: Sprint `1.37` drops the "Vault-Derived Secrets Provider" framing and owns the
  production Vault-Transit `DekCipher`; Sprint `4.30` reframed to the Model-B object-store (HMAC
  opaque IDs, hashed-AAD `prodbox-envelope-v2`, Vault-encrypted index, decoy-pad-to-constant-count,
  one generically-named bucket shared host-CLI ↔ daemon); Sprint `4.33` closed the Haskell-side
  whole-system sealed-state scrub (on-disk, Kubernetes, log surfaces, oracle closure); Sprint
  `7.14` reframed to
  the decrypt-to-scratch Pulumi interposition with Pulumi's secrets provider dropped.

### Validation

1. `prodbox dev lint docs` exit 0 (header↔markers↔registry and relative-link discipline across
   every governed doc).
2. `prodbox dev docs check` exit 0 (this sprint's doc edits touch no generated content).
3. `prodbox dev check` exit 0 — by no-op for the docs-only part.
4. Every governed doc's `**Referenced by**` header and cross-reference list agree (bidirectional
   link discipline), and rule-J harmony holds across `README.md`, `00-overview.md`, the phase
   files, and the legacy ledger. **The back-link half is falsified and superseded by Sprint
   `0.21` (2026-08-05)** — it was never satisfied on any revision. The Standard-J harmony half
   stands.
5. A grep replay confirms no "Option A/B/C" Pulumi ladder and no "long-lived SSE" wording
   survives in any governed doc, the 2026-06-15 historical closure entry reads as a refinement (not a phase
   reopen), and every `📋` / `🔄` implementation status stays honest.

### Remaining Work

- None — the doc and plan rewrites land in this change. The code adoption of Model B lands in the
  cited implementation sprints: the production Vault-Transit `DekCipher` under Sprint `1.37`, the
  Model-B object-store (`Prodbox.Minio.ObjectStore` + `Prodbox.Minio.EncryptedObject`,
  `prodbox-envelope-v2`, HMAC opaque IDs, Vault-encrypted index, decoy-pad-to-constant-count, the
  one generically-named bucket shared by the host CLI and the gateway daemon) under Sprint `4.30`,
  the whole-system sealed-state scrub (oracle closure, log / output redaction, opaque k8s
  namespaces, downstream identity to Vault KV) under Sprint `4.33`, and the decrypt-to-scratch
  Pulumi interposition under Sprint `7.14`; the live sealed-Vault cross-surface red-team is owned
  by Sprint `5.8`. Each closes on its own owned surface when its validation gates pass.

## Sprint 0.15: Phase-Independence Doctrine Adoption ✅

**Status**: Done on the doc-owned surface (2026-06-16). This change lands the
phase-independence doctrine into the standards SSoT and harmonizes the plan suite and governed
docs; it changes only dependency framing, status semantics, and where cross-phase narrative
lives — no objective, feature, or validation is added, removed, or altered. Like Sprints `0.12`
/ `0.13` / `0.14` it is a docs / plan-only sprint, and it **reopens no new phase**: the brief
re-scopes of phase-5 Sprint `5.8` and phase-7 Sprint `7.14` / `7.16` are recorded in the legacy
ledger per `development_plan_standards.md` Standards I / D.
**Implementation**: `DEVELOPMENT_PLAN/development_plan_standards.md` (new Standards N + O and
the A / C / H / M amendments), `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/substrates.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, the per-phase files
(`phase-0-planning-documentation.md` … `phase-8-email-invite-auth.md`, adding per-phase
Independent Validation lines and re-scoping phase-5 Sprint `5.8` and phase-7 Sprint `7.14` /
`7.16`), the governed docs `documents/engineering/vault_doctrine.md` and
`documents/engineering/cli_command_surface.md`, and repo-root `README.md`
**Docs to update**: every file listed above.

**Independent Validation**: Phase 0 is validated on its owned development-plan / governed-doc
surface with no dependency on a later phase — `prodbox dev docs check`, `prodbox dev lint docs`,
and `prodbox dev check` all exit 0 on the home / local substrate, and a grep replay over
`DEVELOPMENT_PLAN/*.md` finds no backward `Blocked by`. No live infrastructure is required to
close this sprint.

### Objective

Adopt the phase-independence doctrine into the standards SSoT and bring the plan suite and
governed documentation into harmony with it, so the development plan lets earlier phases be
validated independently of later phases. An incomplete later phase must never block, gate, or
reopen an earlier phase; reopening is only ever to expand a phase's own owned surface. The
authoritative statement lives in `development_plan_standards.md` Standards N (Phase
Independence) and O (Code-Local vs Live-Infra Proof) plus the amendments to Standards A / C /
H / M; every other doc defers to it. This is a purely structural change to the dependency
model, status semantics, and where cross-phase narrative lives — every objective, feature, and
validation stays exactly the same.

### Deliverables

- `development_plan_standards.md` gains **Standard N (Phase Independence)** — each phase is
  validatable on its owned surface even when any other phase is incomplete, against the home /
  local substrate, a fake, or a stub where a validation would touch a dependency owned by
  another phase; every phase document carries an `Independent Validation` line; forward build
  order is kept but is not a validation gate — and **Standard O (Code-Local vs Live-Infra
  Proof)** — code-local completion (builds + passes local validation: `prodbox dev check`,
  `test unit`, `test integration cli` / `env`) is the phase-closure axis, while a proof needing
  live infrastructure is a non-blocking `Live-proof: pending` note, never `⏸️ Blocked`.
- The amendments to Standards A / C / H / M land: a `Blocked by` may name only an
  earlier-or-same-phase sprint or an external prerequisite, never a later phase or a
  higher-numbered sprint (a backward `Blocked by` is a structural defect to be re-scoped); `⏸️
  Blocked` is reserved strictly for a genuine unmet earlier-phase or external prerequisite; and
  substrate coverage is orthogonal — a suite-content sprint is Done when its validation exists
  and passes on the home substrate, with AWS-substrate coverage tracked only in `substrates.md`'s
  parity table.
- The plan suite is re-scoped to remove backward blocking: phase-5 Sprint `5.8` and phase-7
  Sprint `7.14` / `7.16` are re-scoped so their owned surface is validatable now, with any
  genuinely-later-dependent extension tracked separately via the substrate parity table; each
  reopen is noted briefly per Standard A (reopened to adopt the phase-independence doctrine).
- Per-phase `Independent Validation` lines are added to every phase document stating how the
  phase is validated on its owned surface with no dependency on a later phase.
- Every `⏸️` used only for a live-infrastructure proof (live AWS spend, deployed cluster,
  unsealed Vault, operator-supplied credential) is reframed to Done on the code-owned surface
  plus a non-blocking `Live-proof: pending` note.
- Cross-phase "reopened-phase" narrative relocated to
  `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` per Standards I / D, which also records the
  doctrine shift.
- `README.md`, `00-overview.md`, and `system-components.md` stay in harmony (Standard J); the
  governed docs `vault_doctrine.md` and `cli_command_surface.md` and repo-root `README.md` defer
  to Standards N / O rather than restating the doctrine.

### Validation

1. `prodbox dev docs check` exit 0 (this sprint's doc edits touch no generated content).
2. `prodbox dev lint docs` exit 0 (header↔markers↔registry and relative-link discipline across
   every governed doc).
3. `prodbox dev check` exit 0 — by no-op for the docs-only part.
4. Rule-J harmony holds across `README.md`, `00-overview.md`, the phase files, and the legacy
   ledger.
5. A grep replay over `DEVELOPMENT_PLAN/*.md` finds no backward `Blocked by` (none naming a
   later phase or a higher-numbered sprint), and every `⏸️` that remains names a genuine
   earlier-phase or external prerequisite rather than a live-infrastructure proof.

### Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/vault_doctrine.md` — defer to `development_plan_standards.md`
  Standards N / O for the phase-independence and code-local-vs-live-infra-proof framing of the
  Vault adoption sprints, rather than restating the doctrine.
- `documents/engineering/cli_command_surface.md` — defer to Standards N / O for the
  independent-validation framing of the command-surface sprints.

**Product docs to create/update:**

- Repo-root `README.md` — point to `development_plan_standards.md` Standards N / O as the SSoT
  for phase independence and the code-local-vs-live-infra-proof status axis, per
  [../documents/documentation_standards.md](../documents/documentation_standards.md) (link, do
  not duplicate).

**Cross-references to add:**

- The phase-independence doctrine is cited by name (Standards N / O) per
  `development_plan_standards.md` Standard L wherever a sprint or phase adopts it; all other
  docs defer to that SSoT.

### Remaining Work

None.

## Sprint 0.16: Lifecycle-Control-Plane Architecture and Deployment Qualification ✅

**Status**: Done (2026-07-11; documentation/governance surface)
**Deployment qualification**: pending
**Implementation**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`, the development-plan control documents, all
phase documents, `README.md`, and the governed readiness, lifecycle, config, Vault, gateway,
testing, AWS, storage, chart, prerequisite, and pure-FP doctrines linked by the architecture SSoT
**Independent Validation**: documentation lint, governed-link validation, generated-section drift
checks, and a mechanical sprint-status audit validate this plan-only surface without any later
phase or live infrastructure.
**Docs to update**: `README.md`, `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/README.md`, `documents/engineering/pure_fp_standards.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/config_doctrine.md`, `documents/engineering/vault_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_admin_credentials.md`,
`documents/engineering/aws_account_setup_guide.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/substrates.md`, and `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Define one pure functional target architecture that removes lifecycle authority from the gateway,
makes readiness evidence operation-indexed, and prevents code-local completion from being reported
as current-revision deployment qualification.

### Deliverables

- Define the physical boundaries: minimal pre-Vault Bootstrap Broker, mesh/DNS-only Gateway
  Runtime, retained post-Vault Lifecycle Authority, substrate-local Target Secret Agent, separate
  Authority Backup/TLS Retention Adapters and fenced Provider Worker, permit-created Credential
  Provisioner/Admin Action Runner Jobs, and post-export Decommission Runner.
- Define pure plans and state transitions separately from effect interpreters: typed external
  observations feed total planners; interpreters enact explicit operations and must re-observe
  their postconditions.
- Define the complete initial operation-kind universe, authority-owned config generations, separate
  Lifecycle-provider/Authority-backup/TLS-retention/Gateway-DNS/cert-manager identities, exact
  registered DNS resources, and the
  crash-recoverable encrypted-share/burn-recipient Vault initialization protocol so no unowned
  escape hatch remains in the target.
- Reopen Phases `1`–`8` only on their own expanded surfaces, preserve historical completed
  sprints, and assign the forward-only sprint chain `1.61`–`8.12`.
- Amend the plan doctrine so Standard O remains the phase-completion rule while revision-scoped
  deployment qualification separately gates claims such as "deployment-ready" or "seamless full
  suite."
- Require the stable `LCPC-2026-07-11` frozen old/new reproducer, normalized old→new total-envelope
  mapping, separate production-envelope profile, and secret-safe source/config/image/topology/
  evidence identities before current-composition qualification.
- Record every superseded transport, scheduler, probe binding, synchronous transaction, and
  cleanup path in the legacy-removal ledger with one owning sprint.

### Validation

1. `prodbox dev lint docs` validates governed metadata, links, vocabulary, and Mermaid syntax.
2. `prodbox dev docs check` proves generated documentation is current.
3. `prodbox dev check` is the repository closure gate.
4. A status audit proves `1.61` is the only initially Planned implementation sprint and every
   downstream `Blocked by` points to an earlier phase or lower-numbered same-phase sprint.

### Validation Record (2026-07-11)

- `./.build/prodbox dev lint docs` — exit `0`.
- `./.build/prodbox dev docs check` — exit `0`.
- `./.build/prodbox dev check` — exit `0`, including policy, formatter, linter, and warning-clean
  GHC `9.12.4` build.
- `git diff --check` — exit `0`.
- The mechanical status scan found exactly one `**Status**: Planned` implementation sprint
  (`1.61`) and the complete forward chain `1.61 -> 1.62 -> 2.32 -> 2.33 -> 3.26 -> 4.48 ->
  4.49 -> 4.50 -> 5.18 -> 5.19 -> 6.4 -> 7.33 -> 8.11 -> 8.12`, with every downstream sprint
  `Blocked` by its immediate earlier owner.

### Remaining Work

None on Sprint `0.16`'s plan-owned surface. Implementation begins in Sprint `1.61`; deployment
qualification cannot be claimed by this documentation sprint.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - authoritative process,
  capability, state-machine, persistence, deadline, migration, and qualification architecture.
- `documents/engineering/pure_fp_standards.md` - indexed capability operations, pure transition
  kernels, and effect-interpreter boundaries.
- `documents/engineering/bootstrap_readiness_doctrine.md` - exact capability evidence and the
  Bootstrap Broker/Vault/Lifecycle Authority dependency chain.

**Product docs to create/update:**

- `README.md` - current architecture, reopened implementation state, and deployment-qualification
  status.

**Cross-references to add:**

- Link every reopened phase and the development-plan control documents to
  `lifecycle_control_plane_architecture.md`.

## Sprint 0.17: Foundation Epoch Adoption and Escape-Path Guard ✅

**Status**: Done (2026-07-12; documentation/governance surface)
**Deployment qualification**: pending
**Implementation**: this documentation change — `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md` (Standard P), the phase documents for Phases
`1` / `2` / `4` / `5` / `7`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, and the governed
engineering docs
**Independent Validation**: documentation-only surface; `prodbox dev check`,
`prodbox dev lint docs`, and `prodbox dev docs check` pass; sprint-status and cross-reference
audits confirm Standard H / N / J compliance.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/pure_fp_standards.md`, `documents/engineering/unit_testing_policy.md`,
`documents/engineering/code_quality.md`, `documents/engineering/README.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/vault_doctrine.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, and
`documents/engineering/haskell_code_guide.md`

### Objective

Adopt the Foundation Epoch sequencing correction for counterexample `LCPC-2026-07-11`: amend
Standard P with the interim escape-path guard, shrink-rescope Sprints `1.61` / `1.62`, register
Sprints `1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34` and their deletion-ledger rows,
and encode the compiled-boundary, durability-index, derived-restore, and measured-capacity
doctrine in the governed engineering docs. The four frozen failure mechanisms live at
cross-artifact seams that pure-functional rigor inside one compiled program did not reach; the
corrective doctrine is one typed model, many generated projections. The Foundation Epoch (Sprints
`1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34`) is the active work front and is
executed before Sprints `1.61` and `1.62` as an execution-priority decision; it introduces no
`Blocked by` edge onto the existing `1.61` → `8.12` chain, which resumes unchanged once the epoch
closes.

### Deliverables

- [development_plan_standards.md](development_plan_standards.md) Standard P gains the interim
  escape-path guard: while operational legacy rows remain in `Pending Removal`, every legacy
  escape call site must be enumerated in a machine-readable registry consumed by
  `prodbox dev check`; an unregistered new call site, or a registry entry with no surviving call
  site, fails the build. Qualification remains non-blocking; escape-path drift is not. Registry
  implementation is owned by Sprint `1.63`.
- The Foundation Epoch sprints are registered with full Standard H blocks: Sprints `1.63`
  (conformance tier + legacy escape registry), `1.64` (shared TLS manager + cached Vault
  session), `1.65` (measured capacity certification), and `1.66` (native S3 object-store client,
  Blocked by Sprint `1.64`) in
  [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md); Sprint `2.34`
  (compiled service boundary + latched readiness) in
  [phase-2-gateway-dns.md](phase-2-gateway-dns.md); Sprint `4.51` (durability-indexed retained
  authority storage) in
  [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md); Sprints `5.20`
  (derived restore graph + total executor) and `5.21` (measured resource profile recorder,
  Blocked by Sprint `1.65`) in
  [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md); and Sprint `7.34` (per-run
  postflight residue narrowing) in
  [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md).
- Sprints `1.61` / `1.62` are shrink-rescoped with titles and anchors unchanged: the
  exact-readiness-evidence deliverable moves from Sprint `1.61` to Sprint `2.34`, and the pooled
  native S3 client and the renewable cached Vault session move from Sprint `1.62` to Sprints
  `1.66` and `1.64` respectively.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) gains one Pending Removal
  row per superseded surface, splits the former combined Sprint `1.62` row across the new owners,
  and withdraws the Sprint `7.9` pending removal of the per-run residue constructor (operator
  decision 2026-07-12; `LCPC-2026-07-11` forensics).
- The governed engineering docs encode the corrective doctrine: one typed model / many generated
  projections, durability-indexed coordinates, the derived restore graph and total executor,
  measured capacity certification (Guaranteed QoS retained; honesty by measured-profile
  certification, not limit removal), and the conformance tier joining the canonical quality gate.
- The Deployment Qualification ledger is unchanged — both rows remain pending; nothing in this
  sprint claims qualification.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox dev lint docs` exit 0.
3. `prodbox dev docs check` exit 0.
4. Sprint-status and cross-reference audits confirm Standard H / N / J compliance: the only new
   `Blocked by` edges are Sprint `1.66` → Sprint `1.64` and Sprint `5.21` → Sprint `1.65`, and no
   `Blocked by` names a higher-numbered sprint or later phase.

### Remaining Work

None on this surface — implementation is owned by the registered sprints, and the `1.61` → `8.12`
chain resumes unchanged once the epoch closes.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - measured-profile
  certification of authored envelopes, the Compiled Service Boundary section, durability-indexed
  authority custody, derived cleanup/restore edges, and the conformance-obligation additions.
- `documents/engineering/resource_scaling_doctrine.md` - the Measured Resource Profiles section
  and the explicit throttling-tension resolution (Guaranteed QoS retained; honesty by measured
  certification).
- `documents/engineering/helm_chart_platform_doctrine.md` - the probe/route single-source rule
  and the forbidden-literal chart lint.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - lifecycle-class total verb
  obligations, the derived restore graph and total executor, and the per-run-only postflight
  residue bypass.
- `documents/engineering/pure_fp_standards.md` - the one-typed-model / generated-projections and
  durability-indexed-coordinate patterns.
- `documents/engineering/unit_testing_policy.md` - the conformance-tier definition and the
  planned suite names.
- `documents/engineering/code_quality.md` - the new check families joining the canonical quality
  gate.
- `documents/engineering/README.md` - index and backlink updates for the added sections.
- Conditional harmonizations where prior text contradicted the new doctrine:
  `documents/engineering/distributed_gateway_architecture.md` (latched readiness),
  `documents/engineering/vault_doctrine.md` (cached renewable Kubernetes-auth session),
  `documents/engineering/bootstrap_readiness_doctrine.md` (readiness-evidence rescope pointer),
  and `documents/engineering/haskell_code_guide.md` (shared HTTP manager).

**Product docs to create/update:**

- `README.md` - the Foundation Epoch as the corrective work front, plus the
  measured-certification, latched-readiness, and derived-restoration wording.

**Cross-references to add:**

- Engineering docs name owning sprints sparingly and link the Development Plan; sprint status
  lives only in the plan suite.

## Sprint 0.18: Certificate Scope Policy Adoption ✅

**Status**: Done (2026-07-12; documentation/governance surface)
**Deployment qualification**: pending
**Implementation**: this documentation change — `documents/engineering/acme_provider_guide.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/cluster_federation_doctrine.md`, and
`documents/engineering/README.md`; the `DEVELOPMENT_PLAN` phase-2 / phase-5 sprint registrations
plus `README.md` / `00-overview.md` / `system-components.md` / `legacy-tracking-for-deletion.md`;
and deletion of the root `ZEROSSL_POLICY.md`
**Independent Validation**: documentation-only surface; `prodbox dev check`,
`prodbox dev lint docs`, and `prodbox dev docs check` pass; sprint-status and cross-reference audits
confirm Standard H / N / J compliance.
**Docs to update**: `documents/engineering/acme_provider_guide.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/cluster_federation_doctrine.md`, `documents/engineering/README.md`

### Objective

Adopt an operator-configurable certificate-scope policy that makes an unmanaged or uncovered served
hostname unrepresentable on the prodbox-managed side, and dispose of the orphan ZeroSSL dashboard
(portal) certificate for `vscode.resolvefintech.com` as redundant drift rather than an automation
gap. Certificate scope becomes a Tier-0-configured scope set (exact + wildcard scopes) rather than a
hardcoded wildcard anchor. The Certificate `dnsNames` and exact
`public-edge-tls/<substrate>/<canonical-scope-key>` retention coordinate are total projections of
that set; each explicit Gateway listener/route/DNS served hostname is bound to and covered by the
same set, without attempting to enumerate wildcard coverage. This prevents the independent-list
drift that produced the orphan certificate on the prodbox-managed side. This is a
plan-only governance addition on Phase 0's already-reclosed surface: it registers implementation
Sprints `2.35` (Phase 2) and `5.22` (Phase 5) and claims no implementation sprint or deployment
qualification.

### Deliverables

- The orphan-dashboard-certificate incident disposition is recorded: VS Code stays served at
  `https://test.resolvefintech.com/vscode` on the shared public host under the cert-manager
  `zerossl-dns01` (ZeroSSL ACME over DNS-01 / Route 53) certificate that auto-renews silently and is
  retained across rebuilds as a Vault-Transit-wrapped envelope under
  `public-edge-tls/<substrate>/<canonical-scope-key>`; the operator revokes the orphan certificate
  and unsubscribes from its click-to-renew mail — a manual ZeroSSL-console action outside the
  prodbox-managed surface.
- The target-shape doctrine is encoded in the governed engineering docs: certificate scope is an
  operator-configurable `CertScopeSet`, illegal states (a served hostname not covered by the
  configured scope set; a wildcard anchored at a zone the operator has not delegated in config) are
  made unrepresentable by smart constructors plus fail-fast config validation, wildcard scopes are
  supported only when anchored at a config-declared delegated zone (org-apex wildcards discouraged on
  blast-radius grounds), and the apex requires an explicit exact scope because a wildcard never
  matches the apex or more than one label. Retained restore-vs-reissue matches the exact canonical
  scope-set serialization because cert-manager treats a changed SAN set as a changed issuance
  specification. `impliedBy` remains the narrower-or-equal coverage/admission relation and never
  aliases two retention coordinates.
- Parent→child certificate-material handoff is rejected in favor of delivered `AcmeEabMaterial`
  self-issuance: child clusters self-issue in their own delegated zone and a parent never copies a
  certificate private key into a routinely-destroyed test substrate; certificate material is not a
  member of the closed `RetainedMaterialSchema`.
- Expiry is observed, never driven: `edge status` gains `certificate-renew-due` /
  `certificate-expired` rungs read from cert-manager `status.renewalTime` / `notAfter` (fail-closed
  `certificate-unobservable` when `renewalTime` is absent), with no repo-side renewal-window
  recompute; cert-manager / ZeroSSL own renewal. The CA-layer mitigation (CAA plus RFC 8657
  `accounturi` binding, effective only if the CA enforces `accounturi` — unverified for
  ZeroSSL / Sectigo, and plain CAA does not block same-CA dashboard issuance — with CT-log
  observation as a detection backstop) is recorded as an investigation note, not a shipped or
  guaranteed mechanism.
- Implementation Sprints `2.35` (configurable certificate-scope algebra and derived edge
  projections) and `5.22` (certificate-scope serving validation) are registered with their
  deletion-ledger rows; the root `ZEROSSL_POLICY.md` is retired into the governed engineering docs
  (its ALL-CAPS root name violated documentation_standards §2 and the SSoT topology, and its content
  now lives in the governed docs and the plan suite).

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox dev lint docs` exit 0.
3. `prodbox dev docs check` exit 0.
4. Sprint-status and cross-reference audits confirm Standard H / N / J compliance: the registered
   forward dependencies were Sprint `2.35` → Sprint `2.34` and Sprint `5.22` → Sprint `2.35`;
   both prerequisites are now Done, so Sprint `2.35` is Done and Sprint `5.22` is Planned/unblocked.
   No `Blocked by` names a higher-numbered sprint or later phase.

### Remaining Work

None on this surface — implementation is owned by Sprints `2.35` and `5.22`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/acme_provider_guide.md` — a new "Configurable Certificate Scope" section:
  the certificate `dnsNames` and
  `public-edge-tls/<substrate>/<canonical-scope-key>` retention key as exact projections of one
  configured `CertScopeSet`; explicit listener/route/DNS served-host binding; the coverage /
  narrowing truth table; wildcard DNS-01 issuance over Route 53 (existing solver unchanged); the
  exact-SAN restore-vs-reissue rule and `impliedBy` admission role; the standing
  ZeroSSL-sole-provider and dashboard-cert-is-drift rules; and the CA-layer investigation note.
  Implementation owned by Sprints `2.35` / `5.22`.
- `documents/engineering/envoy_gateway_edge_doctrine.md` — canonical statement 11 rewritten so
  supported public routing serves hostnames that are total projections of the configured scope set
  (wildcards allowed only when anchored at a config-declared delegated zone; org-apex wildcards
  discouraged), the served-FQDN / listener projection paragraph in the traffic and hostname model,
  and the `edge status` `certificate-renew-due` / `certificate-expired` rungs.
- `documents/engineering/lifecycle_control_plane_architecture.md` — §5.4 retention-key
  generalization to a canonical scope-set serialization key; §5.5 exclusion of certificate-material
  handoff from the closed `RetainedMaterialSchema`; §13 scope-coverage / narrowing and
  restore-vs-reissue verification-boundary tables.
- `documents/engineering/cluster_federation_doctrine.md` — child-cluster public-edge TLS is per-zone
  self-issuance with delivered `AcmeEabMaterial`; a parent never hands a child certificate
  private-key material.
- `documents/engineering/README.md` — index-line updates for the four docs above.

**Product docs to create/update:**

- None. The root `ZEROSSL_POLICY.md` is retired (its content now lives in the governed engineering
  docs and the plan suite); the retirement itself is performed outside this phase document.

**Cross-references to add:**

- `documents/engineering/acme_provider_guide.md` gains
  [phase-2-gateway-dns.md](phase-2-gateway-dns.md) and
  [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) referrers;
  `documents/engineering/envoy_gateway_edge_doctrine.md` gains a
  [phase-2-gateway-dns.md](phase-2-gateway-dns.md) referrer. Engineering docs name owning sprints
  sparingly and link the Development Plan; sprint status lives only in the plan suite.

## Sprint 0.19: Repository Secret-Hygiene Doctrine Adoption ✅

**Status**: Done (2026-08-03; documentation/governance surface plus dead-credential removal)
**Implementation**: this documentation change — `documents/engineering/vault_doctrine.md` (new § 20;
§ 19 scope-clarifying sentence), `documents/engineering/code_quality.md` (new
`Credential-Shaped Source Literals` lint subsection), `documents/engineering/unit_testing_policy.md`
(§ 3 forbidden bullet; § 4 amended plus new allowed bullets), and
`documents/engineering/README.md` (index row plus Quick Navigation) — together with the § 20.2
remediation it mandates: deletion of the vestigial hardcoded registry admin credential from
`src/Prodbox/Lib/EksCustomImagePush.hs`, `src/Prodbox/Lib/EksImageMirror.hs`, and
`src/Prodbox/CLI/Rke2.hs`, and correction of the five comment sites that mis-stated the MinIO
bootstrap credential's reachability and precedent.
**Blocked by**: none (governance addition on an already-reclosed surface).
**Deployment qualification**: pending — and, correcting the original entry, this sprint **does** touch
a Standard-P surface: it deleted the credential environment entries from the rendered EKS image-push
Pod and image-mirror Job manifests and removed a `kubectl exec` login step from the push
orchestration, which is capability wiring. Both substrate rows were already `pending`, so nothing is
invalidated, but the next qualification run must exercise the post-`0.19` manifests.
**Independent Validation**: `prodbox dev check`, `prodbox dev lint docs`, and `prodbox dev docs
check` pass. The § 20.1 invariant is verified empirically against the tree: the § 20.5 access-key
pattern over all tracked files yields only exclusion-tagged candidates, and no other § 20.5 provider
pattern occurs in any tracked file. The removed registry credential is proven vestigial — the
rendered registry config carries no `auth` stanza (`test/golden/config/registry-config.yaml`), so it
authenticated to nothing; the affected pod- and Job-manifest suites pass with the former
credential-projection assertions inverted into leak canaries.
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/code_quality.md`, `documents/engineering/unit_testing_policy.md`,
`documents/engineering/README.md`

### Objective

Close the doctrine gap that produced a push-protection rejection on a wholly fabricated credential
fixture: no document governed credential-shaped literals in tracked source. § 19 was the nearest
neighbour and was the wrong owner — its scope is generated artifacts and runtime observation
surfaces, and widening it would have banned the bare access-key prefix and silently vacated the leak
canaries in `test/unit/CredentialProvisionerAwsAdminAuthority.hs` and `test/integration/CliSuite.hs`.
Adopt instead an invariant keyed to scanner-matchability, which the repository already satisfies with
zero exemptions, and make the codebase honest against the stronger "no secrets in source" rule the
same section states.

### Deliverables

- `vault_doctrine.md` § 20 is the SSoT: the no-secret-material rule; the extension of `SecretRef`
  discipline from Tier-0 Dhall to Haskell constants and chart values; the bootstrap-floor exception
  class with its four obligations and its one registered entry; the construct-don't-spell fixture
  convention with four closed load-bearing carve-outs; the scanner-matchability gate with its
  exclusion and boundary semantics; the never-committed list and the `.gitignore` ↔ `.dockerignore`
  pairing rule; and the ordered incident procedure.
- § 19 gains one sentence fixing its scope against § 20, so its access-key entry cannot be read as a
  source-file ban.
- `code_quality.md` gains the lint-surface entry beside `Operator Vocabulary Enforcement` — not in
  `forbiddenPathRegistry`, which is path-shaped — with pattern parity and no-exemption as mandatory
  properties, the tracked-source scope decision, and the record that `prodbox dev check` is the only
  sanctioned gate because repository CI and pre-commit scanners are forbidden surfaces under § 2A.
- `unit_testing_policy.md` § 4's "concrete ADT values and captured payloads" bullet is qualified by
  the § 20 gate, and a new allowed bullet re-permits the four load-bearing categories explicitly, so
  the tightening cannot be misapplied to the canaries.
- The vestigial registry admin credential is deleted rather than carved out, along with the dead
  login step it fed and its stale Haddock referencing a function that no longer exists. The two
  manifest tests that asserted the credential was projected now assert it is absent.
- The MinIO bootstrap credential is registered under § 20.3 with a corrected analysis: the Services
  are `ClusterIP` reached through a port-forward, not a localhost-only NodePort, and the blast radius
  includes registry-blob write access. The former Harbor precedent is withdrawn as vacuous.

### Validation

1. `prodbox dev lint docs` — governed-doc header, `**Generated sections**: none` reconciliation, and
   relative-link resolution across all four touched documents.
2. `prodbox dev docs check` and `prodbox dev check` exit 0.
3. Whole-tree § 20.5 pattern sweep, including over § 20 itself — the doctrine is a tracked file and
   is subject to its own rule (§ 20.7 item 6).
4. Targeted unit suites for the image-push and image-mirror manifests.

### Remaining Work

The three `prodbox dev check` policies § 20 anticipates — the scanner-matchability scan, the
bootstrap-floor registry bijection, and the chart-values literal scan — are registered and not closed
by this sprint, as is the migration of the MinIO bootstrap credential from a compiled-in constant to
a per-install generated value. The scanner-matchability scan is implemented by Sprint `1.75` on the
phase that owns `src/Prodbox/CheckCode.hs`; the other two remain registered and unowned. Sprint `0.20` supersedes this sprint's fixture convention and relocates
the bootstrap-credential registration into `vault_doctrine.md` § 6.1.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/vault_doctrine.md` - new § 20 as the SSoT for credential material in tracked
  content, plus a § 19 sentence fixing that section's scope to generated artifacts and runtime
  observation surfaces.
- `documents/engineering/code_quality.md` - the lint-surface entry, recorded beside the
  operator-vocabulary regex scan rather than in the path-shaped forbidden-path registry.
- `documents/engineering/unit_testing_policy.md` - the test-author-facing fixture rule in the
  forbidden/allowed pattern lists.
- `documents/engineering/README.md` - index row and Quick Navigation entry.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- `documents/engineering/vault_doctrine.md` gains `code_quality.md` and `unit_testing_policy.md`
  referrers; each of those gains a `vault_doctrine.md` referrer. Engineering docs name owning sprints
  sparingly and link the Development Plan; sprint status lives only in the plan suite.

## Sprint 0.20: Repository Value Hygiene Adoption ✅

**Status**: Done (2026-08-03; documentation/governance surface plus committed-value remediation) —
a governance addition on the same already-reclosed Phase 0 documentation surface as Sprints `0.18`
and `0.19`. It neither re-closes nor reopens the phase.
**Implementation**: this documentation change — `documents/engineering/vault_doctrine.md` (§ 20
retitled and restated; § 6.1 gains the integrity blast radius and the generated-per-install
obligation; § 17 ownership reconciled; § 19 red-team bullet), `documents/engineering/code_quality.md`
(the review-enforced-not-lint-enforced boundary), `documents/engineering/unit_testing_policy.md`
(fixture rules generalized from credential-shaped to value-shaped),
`documents/engineering/aws_test_environment.md` (an invented registrable domain replaced with an
RFC 2606 reserved one), `documents/engineering/local_registry_pipeline.md` (a spelled vendor default
credential removed; the build-context claim reconciled against the enumerated copy steps), and
`documents/engineering/README.md`; and the scoping of Exit Definition item 17 to runtime surfaces.
All `vault_doctrine.md` text — including the § 6.1 and § 17 edits — is authored here; the owning
phases adopt it rather than author it. The committed-value remediation on other phases' surfaces
is carried by Sprints `1.74` (Phase 1), `3.30` (Phase 3), `5.26` (Phase 5), and `7.35` (Phase 7).
**Blocked by**: none (governance addition on an already-reclosed surface).
**Deployment qualification**: pending — no Standard-P production-composition surface is touched
(topology, capability wiring, deadline composition, queueing/admission, resource envelopes,
persistence protocol, lifecycle orchestration, destructive cleanup, and substrate routing are all
unchanged), so this neither advances nor invalidates the already-pending qualification, and the
current revision must not be called deployment-ready on the strength of a documentation and
fixture-value change. Note that `SourceIdentity` binds governed documentation, so this change moves
the source-manifest digest a future `proven` row would bind.
**Independent Validation**: Phase-0's governed-documentation surface, validated with no dependency on
any other phase or on live infrastructure — `prodbox dev lint docs`, `prodbox dev docs check`, and
`prodbox dev check` exit 0, plus a cross-reference audit confirming every § 20.x citation resolves to
the section it names and every registered-real-values row resolves to an existing declaration site.
The companion sprints each validate their own remediation on their own surface; this sprint does not
depend on them having landed. Sprint-status and cross-reference audits confirm Standard G / H / J / N
compliance.
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/code_quality.md`, `documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_test_environment.md`,
`documents/engineering/local_registry_pipeline.md`, `documents/engineering/README.md`

### Objective

Generalize Sprint `0.19`'s credential-literal invariant to the class that actually leaked.

An audit prompted by `0.19` established two things. First, the credential class is the **cleanest** in
the repository: 119 credential-imitating fixture literals across 19 test files, and not one realistic
fake — every one is self-labelling or too short to mistake for real. Second, a **real Route 53
hosted-zone id was committed across seven commits** in the version-controlled long-lived stack
settings file, and survived review because it was shape-identical to the synthetic zone ids beside it.
No credential rule would have caught it; a hosted-zone id is not a credential.

The governing insight is therefore not "do not commit secrets" but: **a repository full of realistic
fakes cannot show a real value.** The defect class is *imitation*, and it is widest exactly where no
vendor publishes a placeholder — cloud resource ids — so authors invent shapes that collide with real
ones.

The same audit found that § 20 as written by `0.19` restated roughly 30% of its own file (§ 3, § 4,
§ 13, § 17, and `.gitignore`), which `documentation_standards.md` § 5 forbids, and that the
restatement had introduced three unreconciled contradictions.

### Deliverables

- `vault_doctrine.md` § 20 is retitled *Repository value hygiene* and restated around the three-way
  rule — officially synthetic, unmistakably synthetic, or genuinely real and declared as such in
  place — with a placeholder registry naming the reserved value for each class and marking the
  cloud-resource-id row as the one with no vendor placeholder.
- The duplication is removed: § 20 now links § 3, § 4, § 13, § 17, and `.gitignore` instead of
  restating them.
- The bootstrap-floor credential registration is folded back into § 6.1, which already carried it,
  and gains the fact § 6.1's confidentiality-only argument missed: the credential grants **write**
  access to the container-registry blob store, so overwritten blobs are pulled as trusted images —
  an integrity exposure, not merely ciphertext access. The generated-per-install obligation is edited
  into § 6.1 so it amends the stability justification rather than contradicting it from elsewhere.
- § 17's closing sentence is reconciled: the MinIO root credential is Vault-*mirrored*, not
  Vault-owned; its authoritative value is the § 6.1 bootstrap constant.
- § 20.5 is demoted to an explicitly mechanical outer ring, with the reason its exclusion list is
  narrower than § 20.1's stated in place — the two rules have different judges, one a scanner and one
  a reader.
- The `0.19` fixture convention is withdrawn. Nothing in the codebase validates fixture shape — the
  admin-credential validator enforces non-emptiness and the SMTP key-id constructor enforces an
  alphanumeric bound — so imitation was decoration, and constructing a credential-shaped value merely
  hid it from a scanner. Fixtures are unmistakably synthetic; only published vendor test vectors are
  immovable.
- A leak canary asserts the absence of *the value the test passed in*, never of a vendor prefix,
  which silently weakens as fixtures stop imitating.
- Exit Definition item 17 is scoped to runtime surfaces, resolving its conflict with the doctrine's
  preference for reserved placeholders in examples and fixtures.
- Twelve committed-value defects are remediated across Sprints `1.74`, `5.26`, `7.35` and this one.

### Validation

1. `prodbox dev lint docs` — governed-doc headers, `**Generated sections**: none` reconciliation, and
   relative-link resolution across all six touched documents plus the retitled § 20 anchors.
2. `prodbox dev docs check` and `prodbox dev check` exit 0.
3. `prodbox test unit` at 3066/3066 with the fd-flaky real-`ssh` case excluded — unchanged from before
   the fixture-value remediation, which is the proof those values were behaviourally inert.
4. Whole-tree self-check: the § 20.5 patterns run over the edited documents, since a governed doc is
   tracked content and subject to the rule it states.
5. Defect sweep: each remediated value returns its synthetic replacement and no routable address,
   RFC 4122-shaped Kubernetes UID, invented registrable domain, spelled vendor default credential, or
   real per-run cloud resource id survives.
6. Contradiction audit: the MinIO bootstrap credential holds one consistent position across § 6.1,
   § 17, and § 20; Exit Definition item 17 and § 20.1 no longer conflict.

### Remaining Work

None. Of the three `prodbox dev check` policies registered by Sprint `0.19`, the
scanner-matchability scan is closed by Sprint `1.75` on the phase that owns the quality gate; the
bootstrap-floor registry bijection and the chart-values literal scan remain registered and unowned.
None is affected by this sprint — the § 20.1 committed-value rule is deliberately review-enforced
rather than lint-enforced, because no scanner can distinguish a real cloud resource id from a
synthetic one, and § 20.5 is the separate mechanical ring Sprint `1.75` implements. The migration of the MinIO bootstrap credential to a per-install generated
value likewise remains scheduled.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/vault_doctrine.md` - § 20 retitled and restated as the SSoT for committed
  values; § 6.1 gains the integrity blast radius and the generated-per-install obligation; § 17
  ownership reconciled; § 19 gains a red-team bullet.
- `documents/engineering/code_quality.md` - records that the committed-value rule is review-enforced
  rather than lint-enforced, and why adding a pattern for it would be wrong.
- `documents/engineering/unit_testing_policy.md` - fixture rules generalized from credential-shaped
  to value-shaped.
- `documents/engineering/aws_test_environment.md` - the ephemeral-subdomain example uses an RFC 2606
  reserved domain.
- `documents/engineering/local_registry_pipeline.md` - the retired component's default credential is
  described rather than spelled; the build-context claim matches the enumerated copy steps.
- `documents/engineering/README.md` - index row and Quick Navigation entry.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- `DEVELOPMENT_PLAN/README.md` Exit Definition item 17 links `vault_doctrine.md` § 20.1 and states
  the runtime-surface scoping. `documents/engineering/aws_test_environment.md` and
  `local_registry_pipeline.md` gain `vault_doctrine.md` links. Record the Phase `1`, `5`, and `7`
  own-surface reopens in [README.md](README.md) and [00-overview.md](00-overview.md), and add the
  remediated-value rows to
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 0.21: Governed-Document Metadata Reconciliation ✅

**Status**: Done (2026-08-05; documentation/governance surface plus the two lint gates it adds) —
a governance addition on the same already-reclosed Phase 0 documentation surface as Sprints `0.18`,
`0.19`, and `0.20`. It neither re-closes nor reopens the phase.
**Implementation**: `src/Prodbox/CheckCode.hs` (the `**Status**:` value-legality gate —
`governedDocStatusValues`, `parseGovernedDocStatusField`, `governedDocStatusViolations`,
`checkGovernedDocStatusValues`; and the cited-source-path existence gate —
`retiredCitedSourcePaths` derived from the extracted `removedLegacyTransportSourcePaths` SSoT,
`inlineCodeSpansInLine`, `isCitedSourcePath`, `citedSourcePathsInDoc`,
`checkPlanCitedSourcePaths`, both wired into `runGovernedDocChecks`), `test/unit/Main.hs`
(16 cases in the Sprint 0.9 documentation-harmony group), the operator-facing remedy hint and
generated-artifact banners corrected from the non-existent `prodbox docs generate` to
`prodbox dev docs generate` (`CheckCode.hs`, `src/Prodbox/CLI/Docs.hs`,
`src/Prodbox/Lifecycle/ResourceClass.hs`, `src/Prodbox/Infra/StackDescriptor.hs`, and the three
regenerated `share/completion/` artifacts), and the strike of the `**Referenced by**:` field from
`documents/documentation_standards.md` § 1/§ 3/§ 4/§ 10, its co-owner
`documents/engineering/README.md`, `documents/engineering/code_quality.md`, and all 62 governed
documents.
**Blocked by**: none (governance addition on an already-reclosed surface).
**Deployment qualification**: pending — no Standard-P production-composition surface is touched
(topology, capability wiring, deadline composition, queueing/admission, resource envelopes,
persistence protocol, lifecycle orchestration, destructive cleanup, and substrate routing are all
unchanged), so this neither advances nor invalidates the already-pending qualification. Note that
`SourceIdentity` binds governed documentation, so this change moves the source-manifest digest a
future `proven` row would bind.
**Independent Validation**: Phase-0's governed-documentation surface plus its own lint gates,
validated with no dependency on any other phase or on live infrastructure —
`prodbox test unit -p "Sprint 0.21"` 16/16; `prodbox dev lint docs`, `prodbox dev docs check`, and
`prodbox dev check` exit 0; the cited-path gate demonstrably fails closed, having flagged nine real
stale citations on its first run (`system-components.md`'s three phantom modules, Sprint `4.47`'s
`CheckpointAuthorityStore.hs`, and Sprint `4.51`'s two dead Increment-B citations across two files)
and passing only after each was repaired; and
`grep -rn '^\*\*Referenced by\*\*:' documents/ DEVELOPMENT_PLAN/ README.md CLAUDE.md AGENTS.md`
returns zero hits.
**Docs to update**: `documents/documentation_standards.md`, `documents/engineering/README.md`,
`documents/engineering/code_quality.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `DEVELOPMENT_PLAN/README.md`

### Objective

Make the governed-document header block mean something. Of its four fields, `**Generated
sections**:` was already machine-reconciled and `**Status**:` / `**Referenced by**:` were
review-enforced conventions that had rotted. Enforce the fields that are derivable from an SSoT;
strike the one that is not.

### Deliverables

- A closed `**Status**:` value set, rejecting anything outside the four values § 3 enumerates.
  `documentation_standards.md` § 9 already named `**Status**: WIP` an anti-pattern with nothing
  behind it.
- A cited-source-path existence gate over `DEVELOPMENT_PLAN/`: every backtick-quoted
  `src/…​.hs` / `test/…​.hs` citation resolves in the worktree, or is a declared historical
  retirement. Glob families, brace expansions, and angle-bracket placeholders are excluded — they
  name a set, not an artifact a reader can open.
- `retiredCitedSourcePaths` derives from `removedLegacyTransportSourcePaths`, the list the
  removed-legacy-transport negative-space lint already asserts must stay deleted. One SSoT, not a
  second hand-authored copy.
- The `**Referenced by**:` field struck from the standard and from all 62 governed documents
  (480 physical lines), with the reverse edge recovered by search instead.
- The operator-facing remedy hint and every generated manpage/completion banner name a command
  that exists.

### Validation

1. `prodbox test unit -p "Sprint 0.21"` 16/16.
2. The cited-path gate fails closed: restoring any of the nine repaired citations reproduces a
   named violation, and the gate passes again once corrected.
3. The `**Status**:` gate rejects `WIP` and a missing field, and accepts all four legal values.
4. Zero `^**Referenced by**:` occurrences survive under `documents/`, `DEVELOPMENT_PLAN/`, or the
   three root documents; no `src/`, `test/`, or `app/` code parses the field.
5. `prodbox dev lint docs`, `prodbox dev docs check`, and `prodbox dev check` exit 0.

### Closure Evidence

The strike is evidence-led, not stylistic. Generating the field mechanically produced 52 entries
(2,421 characters) on `DEVELOPMENT_PLAN/README.md` and over 1,500 characters on three doctrine
hubs; scoping it to `documents/`-only referrers cut roughly a third and did not rescue it.
Inverting the authored field across all 62 documents measured **53 stale and 660 missing**
entries — about 7% complete and 8% wrong — and **no entry carried information `grep -rl` could not
reconstruct exactly**. `AGENTS.md` claimed `CLAUDE.md` as a referrer while `CLAUDE.md` never
mentioned it; every phase file claimed `documents/engineering/README.md`, which mentions no phase
file; that index listed itself.

The field was derived data cached in a second location, which § 1 already forbade. Search answers
the same question at section granularity the field never could —
`lifecycle_reconciliation_doctrine.md § 3.1` alone is cited from twelve source files.

This also falsifies a criterion Sprints `0.12`, `0.13`, and `0.14` each closed on — "every governed
doc's `**Referenced by**` header and cross-reference list agree" — which was never satisfied on any
revision. Per Standard C those closures carry dated correction notes rather than being rewritten,
and the Sprint `1.61` Standard-G bullet instructing a back-link addition is marked superseded.

### Remaining Work

None.

## Sprint 0.22: Doctrine Section-Citation Existence Gate ✅

**Status**: Done (2026-08-05) — a governance addition on the same already-reclosed Phase 0
documentation surface as Sprints `0.18`–`0.21`. It neither re-closes nor reopens the phase.
**Implementation**: `src/Prodbox/CheckCode.hs` (`documentSectionNumbers`, `headingSectionNumber`,
`boundSectionCitationsInLine`, `stripHaddockMarkup`, `boundDocumentName`,
`checkDoctrineSectionCitations`, wired into `runGovernedDocChecks`), `test/unit/Main.hs` (12 cases),
and the one broken citation it exists to prevent recurring, in
`documents/engineering/cli_command_surface.md`.
**Blocked by**: none.
**Deployment qualification**: pending — no Standard-P production-composition surface is touched.
**Independent Validation**: pure plus a repo-wide scan, no live infrastructure —
`prodbox test unit -p "Sprint 0.22"` 12/12; the gate reports zero findings across the tree (the
false-positive test); and a probe document citing a nonexistent
section 99 of `config_doctrine.md` is rejected, while a citation of its real § 7 passes (the false-negative test). `prodbox dev check` exit 0.
**Docs to update**: `documents/engineering/cli_command_surface.md`

### Objective

Code and documentation cite doctrine sections by number — 1,714 numeric citations across 114 files,
with `vault_doctrine.md` (229), `config_doctrine.md` (139), and
`lifecycle_reconciliation_doctrine.md` (114) the heaviest targets. Nothing verified that any of them
resolved to a real heading. `src/Prodbox/CheckCode.hs` is itself the sixth-heaviest citing file, and
~25 sites emit section citations into operator-facing output.

### Deliverables

- A heading-number reader over the uniform grammar the doctrine set already uses (`## 7.`,
  `### 3.1`, `## 2C.`, `### 5a.1.`).
- A citation binder that pairs a `§` marker with a document only when the pairing is lexically
  unambiguous, and refuses to bind across a letter, `;`, or `.`.
- Exclusions with a measured reason: external standards (`RFC 8949 § 4.2`), the three-or-more-digit
  line-number convention used in four phase files, and Haddock `@`/`\` markup, which would
  otherwise make `@…md § 3@` tokenize as section `3@`.

### Validation

1. `prodbox test unit -p "Sprint 0.22"` 12/12.
2. Zero findings across the tree — 774 of 777 bound citations already resolved, and the remaining
   two are deliberate absolute paths into a sibling repository, which the gate skips because it
   only resolves documents present in this repo.
3. A probe document citing a nonexistent section 99 of `config_doctrine.md` is rejected, while a
   citation of that document's real § 7 passes.
4. `prodbox dev check` exit 0.

### Honest scope — what this gate does NOT cover

**It cannot catch the defect that motivated it.** `cli_command_surface.md` cited `§3B`, a section
that exists nowhere; the heading it pointed at lives under `§4`. That is a **self-reference** — no
document name appears near the marker — and self-references are not safely checkable. Measured over
`documents/engineering/`, treating a bare `§N` as a self-reference leaves 63 of 639 unresolved
(9.9%), and spot-checking shows most of those are cross-document references whose target is named
earlier in the sentence. A gate with a one-in-ten false-positive rate would be turned off, so the
937 bare citations tree-wide are deliberately out of scope. The `§3B` defect was repaired by hand in
this sprint; a recurrence of that specific class would not be caught.

**So this gate catches nothing today.** Its value is regression protection for an operation this
repository actually performs: Sprint `0.21` renumbered six doctrine sections and swept 43 anchor
citations by hand. Renumbering a section silently breaks every bound citation to it, and that is
precisely what this now refuses to let through. It is insurance against a future sweep being
incomplete, not a discovery tool — and the plan's earlier claim that it "finds one real defect
today" was falsified by the mutation test and is corrected here.

### Remaining Work

None. Extending coverage to self-references would need a binding signal stronger than adjacency;
none was identified at an acceptable false-positive rate.

## Sprint 0.23: Correct the Tier-0 Config Doctrine Against Source ✅

**Status**: Done (2026-08-07) — a governance correction on the same already-reclosed Phase 0
documentation surface as Sprints `0.18`–`0.22`. It neither re-closes nor reopens the phase.
**Implementation**: `documents/engineering/resource_scaling_doctrine.md` (§ 2C Ring-1 cell),
`documents/engineering/config_doctrine.md` (the version-control inventory claim, its section
heading, and a new "What decoding does and does not validate" subsection under § 4),
`documents/engineering/code_quality.md` (§ 3 guard coverage), and
`documents/engineering/chaos_hardening_doctrine.md` (§ 21 worked instances).
**Blocked by**: none.
**Deployment qualification**: pending (unchanged) — documentation only; no production-composition
surface is touched.
**Independent Validation**: pure, no live infrastructure. Each corrected claim was checked against
source before rewriting: `git ls-files "*.dhall"` returns five tracked files;
`grep -c assert prodbox-config-types.dhall` returns zero;
`git ls-files --error-unmatch prodbox-config-types.dhall` fails and the path appears nowhere in
`src/Prodbox/CheckCode.hs`. `prodbox dev check`, `dev docs check`, and `dev lint docs` exit 0, which
is also the mechanical proof that the new text satisfies Sprint `0.21`'s cited-source-path gate and
Sprint `0.22`'s section-citation gate.
**Docs to update**: the four listed above.

### Objective

Three governed-document claims about the Tier-0 config surface were false against source. All three
were load-bearing — each one made a reader believe a guarantee that is not in force.

1. **`resource_scaling_doctrine.md` § 2C** defended the Dhall enforcement ring with *"`prodbox.dhall`
   is binary-generated (no human Dhall authoring surface)"*. The cell contradicted itself one
   sentence later by claiming value for catching *"a host-shrinking hand-edit"*. `prodbox.dhall` is
   hand-editable: `config generate` tells the operator to edit it directly, `CLAUDE.md` lists
   editing it against the generated schema as the **automation** path, and the `ses.*`,
   `pulumi_state_backend.*`, and `aws_substrate.*` sections have no generator path at all.
2. **`config_doctrine.md`** asserted *"Net: zero version-controlled `.dhall`"* under a heading
   making the same claim. Five `.dhall` files are tracked — four hand-authored algebra schemas under
   `dhall/` and one golden fixture. They are tracked by design; the claim was meant to scope to the
   config surface and did not say so.
3. **`code_quality.md` § 3** listed `prodbox-config-types.dhall` as *"a tracked generated path
   regenerated by `prodbox config generate`"*. Both halves were wrong: the file is git-ignored, and
   it appears nowhere in `CheckCode.hs`, so no registry entry and no gate covers it.

### Validation

1. Every corrected claim was verified against source first; the commands are listed under
   Independent Validation above and each is reproducible.
2. § 2C keeps the shim's real value while naming its true scope — the resource-plan arithmetic only,
   trusting its own emitted draws, with every other hand-edited field unguarded until Ring 2.
3. `config_doctrine.md` § 4 now states what decoding does **not** validate: the gate is not total
   over the record, and `ValidatedSettings` carries the raw record with the capacity plan as its one
   required proof.
4. `chaos_hardening_doctrine.md` § 21 gains the config surface as worked instances of classes **D**
   and **G** by thin cross-reference only, per its own § 1 DRY rule — no new doctrine, and the
   `ValidatedSettings` worked example above it is unchanged because the required-field mechanism it
   describes does hold.
5. `prodbox dev check`, `dev docs check`, `dev lint docs` all exit 0.
6. **`system-components.md` deliberately does not change** (Standard F wants the decision recorded,
   not silently skipped). Its capacity row states that over-commit is unrepresentable at the Haskell
   decode gate because the proof is a required field of `ValidatedSettings` — the audit confirmed
   that mechanism holds, since `AllocatedResourcePlan` has a hidden constructor and one minter. The
   corrections above narrow what *else* `ValidatedSettings` proves, which the inventory never
   claimed. No component, control surface, or authority boundary moved.

### Remaining Work

None on this sprint's surface. The code changes these corrections describe are owned by Sprints
`1.79`–`1.81`; the missing drift gate is Sprint `0.24`.

## Sprint 0.24: Tier-0 Drift Gate for the Binary-Sibling Config ✅

**Status**: Done (2026-08-07) — a governance addition on the same Phase 0 enforcement
surface as Sprints `0.21`/`0.22`. It neither re-closes nor reopens the phase.
**Implementation**: `src/Prodbox/CheckCode.hs` (`checkTier0SiblingDrift`, `tier0DriftFindings`,
`tier0DriftLocation`, `tier0MalformedFinding`, `trackRecordScope`, `fieldAssignmentInLine`;
`runConformanceTierChecks` now gates on it and delegates the registry chain to
`runConformanceTierRegistryChecks`), `test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending — no production-composition surface is touched; the gate is a
developer-tooling check that only reads the sibling file.
**Independent Validation**: pure plus a filesystem read, no live infrastructure — a named `-p`
filter with an exact count, plus a mutation exercise that hand-edits a generated sibling config,
confirms the gate fires, and restores byte-exactly.
**Docs to update**: ✅ `documents/engineering/code_quality.md`, ✅ `documents/engineering/config_doctrine.md`

### Objective

Nothing detects drift between the binary-sibling `prodbox.dhall` and what the generator would emit.
A hand edit persists silently and survives a `config setup` re-run, because `configFromSetupInput`
carries every unprompted field forward from the existing file. The only mechanical ring over a hand
edit today is the Ring-1 Dhall `assert`, which covers the resource-plan arithmetic and nothing else
— it is blind to a hand-edited `route53.zone_id`, `acme.server`, `domain.cert_scopes`, `ses.*`, or
the component graph.

**The constraint that shapes the design**: the existing tracked-generated-path registry and the
credential scan are deliberately scoped to version-controlled content — `src/Prodbox/CheckCode.hs`
states that scope is tracked content, not a filesystem walk — and `prodbox.dhall` is git-ignored. So
this gate cannot reuse that machinery. It must read the binary-sibling path directly, and it must
tolerate the file being absent, since a fresh worktree has no sibling config until
`config generate` runs.

### Deliverables

- ✅ A drift check that re-renders the parameters from the decoded record and compares, reporting the
  differing field rather than a whole-file diff. `checkTier0SiblingDrift` resolves the sibling path
  through `resolveTier0ConfigPath` (never a filesystem walk, never the repo root), decodes it with
  `decodeProjectConfigDhall`, and compares `renderProjectConfigDhall` of the decoded record against
  the bytes on disk. The reported field is recovered from the canonical rendering's own indentation
  by an indentation-keyed scope stack, so the message names `parameters.domain.demo_ttl`, not a byte
  offset. Type annotations and `let` bindings — of which the emitted Ring-1 preamble is full — are
  rejected as field names, and the pretty-printer's dotted single-field shorthand
  (`, route53.zone_id = ""`) is recovered as one name.
- ✅ Absence is not a finding. A malformed file is a finding distinct from a drifted one:
  `tier0MalformedFinding` says the file does not decode and names no field, because an undecodable
  file has no record to re-render.
- ✅ An error-message contract matching the § 3 convention: the path, what drifted (line plus field
  path), and the remedy (`prodbox config generate`, or `prodbox config setup` for the operator
  sections).

### Validation

1. ✅ A generated config passes; a hand-edited one fails naming the drifted field; an absent one is
   silent. All four dispositions were exercised against the live `.build/prodbox.dhall`:
   - unchanged generated config → `dev check` exit 0;
   - hand edit to `capacity.resource_plan.workload_profiles[keycloak].memory_demand.steady_memory_terms_mib`
     (`[ 1024 ]` → `[ 512 ]`) → exit 1 with
     `.build/prodbox.dhall has drifted from the generator's canonical rendering at line 4215, field `memory_mib``;
   - a file replaced by `let x = y in x` → the malformed finding, not a drift finding;
   - the file removed entirely → exit 0, silent.
2. ✅ The mutation exercise restores byte-exactly (`sha256sum -c` against the pre-mutation digest:
   `OK`), and `dev check` returns to exit 0 afterward.
3. ✅ `prodbox dev check` exit 0.
4. ✅ `prodbox-unit -p "Sprint 0.24"` — 8/8, covering the silent, drifted, dotted-shorthand,
   sibling-scope-close, truncated, appended, preamble-rejection, and malformed cases.

### Remaining Work

None on this sprint's surface. The honest bound is now stated in the two governed documents rather
than only here, because the first mutation attempted proved it: a drift gate detects divergence from
the generator's **output**, so it closes representational drift — a hand edit that changes the
emitted text, a file left by an older schema, and (the sharp case) a hand-edited resource plan whose
emitted `concurrentDraws` witness goes stale, which is the Ring-1 `assert`'s own input and had been
letting Ring 1 prove the fit of draws the plan no longer implied. It does **not** close a hand edit
to a primitive that round-trips: a re-typed `route53.zone_id` decodes to that value and re-renders to
that value, so the edited file *is* the generator's output for the record it carries, and no text
comparison can separate the two. That was verified, not assumed — the first mutation exercise edited
`route53.zone_id` and `dev check` correctly stayed at exit 0.

Closing the residual class needs a generator-stamped witness over the record (the Tier-0 `witness`
field exists for exactly that). That is deliberately **not** absorbed here: it changes the content of
every generated `prodbox.dhall`, which is a Standard-P generated-config-identity change, and this
sprint's declared scope is a developer-tooling check that touches no production-composition surface.
It is registered as a scheduled gap in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rather than closed silently
([Standard L](development_plan_standards.md#l-cli-doctrine-alignment)).

## Sprint 0.25: Conversions, and the Region of a Ring ✅

**Status**: Done (2026-08-08) — a governance correction on the same already-reclosed Phase 0
documentation surface as Sprints `0.18`–`0.24`. **It neither re-closes nor reopens the phase.**
**Implementation**: `documents/engineering/chaos_hardening_doctrine.md` (new § 23; § 22 ring cell and
a fourth honest consequence; § 21's sufficiency claim corrected; a § 12 ledger row),
`documents/engineering/resource_scaling_doctrine.md` (§ 2C Ring-2 cell, Ring-1 cell, and the new
"The region of Ring 2" subsection), `documents/engineering/code_quality.md`,
`documents/engineering/config_doctrine.md`, `documents/engineering/unit_testing_policy.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/pure_fp_standards.md` (new § 2.3a),
`documents/engineering/haskell_code_guide.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, and the root `README.md`.
**Blocked by**: none.
**Deployment qualification**: pending (unchanged) — documentation only. No production-composition
surface moves.
**Independent Validation**: every claim added was measured, not asserted. The two load-bearing ones:
`cabal build --builddir=.build all --dry-run` lists two components (`lib`, `exe:prodbox`) where
`--enable-tests --dry-run` lists ten, which is the region finding; and the three-conversion trace
was read end to end from `test/integration/CliSuite.hs` through `src/Prodbox/Http/Client.hs` to
`src/Prodbox/Settings.hs`. `prodbox dev docs check`, `prodbox dev lint docs`, and `prodbox dev check`
exit 0.
**Docs to update**: the ten files named above.

### Objective

Two claims the governed corpus made are incomplete, and closing a MISU gap exposed both.

Sprint `1.80` retyped `deployment.public_edge_advertisement_mode` into a closed Dhall union —
precisely the class-D move `chaos_hardening_doctrine.md` § 21 prescribes, on the field § 21 names as
its own worked example. Applying it broke twenty integration cases and the failure surfaced as
`NoResponseDataReceived`, a transport error naming nothing. Five minting-boundary gates, a Ring-1
`assert`, a Ring-2 decode gate and the Sprint `0.24` drift gate were all in force; none fired.

### Deliverables

- ✅ **`chaos_hardening_doctrine.md` § 23 — "Conversions — where the moves stop."** Every § 21 move
  constrains what a value can be *inside* a region and says nothing about what happens when it
  leaves. The rule: *a typed value crossing out of a region must be reconstructed by exactly one
  derived encoder, or the region's proofs end at the crossing.* Three corollaries — count the
  encoders; do not convert a typed failure into an untyped one; remove the conversion before adding
  a proof. Appended after § 22 rather than added as a ninth § 21 row, because a conversion is not a
  missing coordinate — it is where all eight are discarded at once.
- ✅ **§ 22 gains a fourth honest consequence: a ring has a region.** The Ring-2 cell now reads
  "**Yes — within its compiled region**".
- ✅ **§ 21's "Neither needs new doctrine" is corrected in place.** That sentence was written about
  the two config-surface instances; closing one of them produced this outage. The table was right
  about the coordinate and wrong about the sufficiency, and the correction says so rather than
  quietly amending.
- ✅ **§ 12 gains a ledger row.** *Type tightening inside a region* → **Proven for the compiled
  region only** → does not establish anything at a conversion out of it.
- ✅ **`resource_scaling_doctrine.md` § 2C owns the region**, per § 22's own delegation of the ring
  vocabulary. New subsection "The region of Ring 2" carries the measurement and two rules: state the
  region whenever you state the ring; a gate's region must cover the surface carrying its evidence.
  A fourth table column was deliberately not added — the existing cells run past a thousand
  characters and a column would have cost more legibility than it bought.
- ✅ **`code_quality.md` names the asymmetry sitting in its own step list.** Steps 3 and 4 are scoped
  `app src test`; step 5 is scoped `all`, which is `lib` plus `exe:prodbox`. Three consecutive lines,
  previously unremarked.
- ✅ **`config_doctrine.md` records the repository consequence of Sprint `1.80`**, which had recorded
  only the operator one (regenerate the sibling file). Four hand-written Tier-0 encoders existed;
  one was updated.
- ✅ **`unit_testing_policy.md` and `integration_fixture_doctrine.md` state what the canonical gate
  does not compile**, and the fixture doctrine gains two binding consequences: a fixture that
  hand-authors a serialized production type is a second encoder, and a fixture server answers or
  refuses but never closes silently.
- ✅ **`pure_fp_standards.md` § 2.3a — "Encode at exactly one boundary."** § 2.3 governed the read
  direction and had no mirror; that absence is what let four encoders of one record coexist.
- ✅ **Root `README.md`** says the four fast-validation commands are separate surfaces, not
  redundant ones.

### Validation

1. ✅ `prodbox dev docs check` exit 0 — governed-doc harmony, relative links, `**Status**:` values,
   cited source paths, and doctrine section citations.
2. ✅ `prodbox dev lint docs` exit 0 (identical coverage; run explicitly).
3. ✅ `prodbox dev check` exit 0.
4. ✅ **The section-citation gate did its job during authoring** and is worth recording as evidence
   rather than as a footnote: a first draft of the `bootstrap_readiness_doctrine.md` cross-reference
   placed `§ 0.5` directly after a link to `chaos_hardening_doctrine.md`, and
   `checkDoctrineSectionCitations` bound the number to the wrong document and failed the build. The
   citation was rewritten to name its own section in prose.
5. ✅ No section was renumbered. § 23 is appended, so the ~40 bound `§ 21` / `§ 22` citations across
   `documents/`, `DEVELOPMENT_PLAN/` and `src/` Haddock — plus the ~9 unbound ones in
   `legacy-tracking-for-deletion.md` that no gate protects — are untouched.

### Remaining Work

None on this sprint's surface. The code that closes the two defect classes is Sprints `5.30` and
`4.60`; this sprint states the doctrine they implement and does not depend on them.

## Sprint 0.26: An Observation Has a Layer ✅

**Status**: Done (2026-08-10) — governance work on the already-reclosed Phase `0`
documentation surface; it neither re-closes nor reopens the phase (Sprint `0.17`'s reclosure
stands). Registered by a live `prodbox test all --substrate aws` failure whose cause was a derived
value read at the wrong layer, and by the discovery that a chart-doctrine claim is wider than the
region enforcing it.
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated) — this sprint changes governed documentation only and
moves no production-composition surface; both substrate rows stay `pending`. Note that
`SourceIdentity` binds governed documentation, so these edits do move the source-manifest digest a
future `proven` row would bind.
**Independent Validation**: `prodbox dev check` exit 0, which runs the governed-document harmony
set — status values, relative links, generated-section harmony, and the section-citation existence
gate over the new § 24.
**Docs to update**: `documents/engineering/chaos_hardening_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/code_quality.md`.
**Implementation**: `documents/engineering/chaos_hardening_doctrine.md` (§ 24 and its § 12 ledger row), `documents/engineering/helm_chart_platform_doctrine.md` and `documents/engineering/code_quality.md` (the in-place probe/route single-source correction). Documentation-only: this sprint compiles nothing, so the Standard-H field names the governed documents it authored rather than a `src/` path it did not touch. Back-filled by Sprint `0.27` from this sprint's own body.

### Objective

Sprint `0.25` established that MISU stops at conversions: a value crossing out of a region must be
reconstructed by exactly one derived encoder. A live failure showed that rule is satisfiable by a
value that is still wrong.

`apiEgress` in `src/Prodbox/Lib/ChartPlatform.hs` renders the NetworkPolicy permitting a workload to
reach the Kubernetes API. It does not hand-author its coordinate — `readKubernetesApiServiceIpv4`
observes `service/kubernetes`, and the rule is generated from that observation, exactly as § 21's
class-G prescribes. It is wrong in **both** coordinates anyway. The Service is `10.43.0.1:443` with
`targetPort=6443`; the endpoint is `192.168.2.43:6443`; kube-proxy DNATs before the CNI evaluates
egress, so the policy is matched against the endpoint and a rule naming the Service matches nothing.
The observation was authoritative for the layer at which a client dials, and was read for the layer
at which policy is evaluated.

That is not a missing coordinate on a value (§ 21) and not a second encoder (§ 23). It is a source
read at the wrong layer, and no existing section names it.

### Deliverables

- ✅ **`chaos_hardening_doctrine.md` gains § 24, "An observation has a layer."** The rule: *a derived
  value is only as correct as the layer at which its source object is authoritative, and that layer
  must match the layer at which the value is enforced.* Deriving from one source fixes the encoder
  count, not the layer. Carries the measured worked example, the control test that separated the two
  candidate causes, and the corollary that a layer mismatch is not a duplicate — the client-dial and
  policy-match coordinates are both correct at their own layer, and collapsing them breaks the
  client path.
- ✅ **A § 12 ledger row.** "Derivation from an observed source (§ 24)" establishes agreement with the
  object actually read, is **proven only for the layer at which that object is authoritative**, and
  does not establish that the layer read is the layer enforced.
- ✅ **`helm_chart_platform_doctrine.md`'s probe/route single-source rule is corrected in place
  (Standard C).** The passage states the rule as a property of every chart; `prodbox dev lint chart`
  enforces it on seven charts, on hand-listed filenames, and only the gateway rule covers ports at
  all. No chart's `networkpolicy.yaml` is inspected for content by any gate —
  `chartTemplateResourceViolations` opens every template but reads `containers:` stanzas, which a
  NetworkPolicy has none of. Measured: 79 numeric port literals across 13 charts sit outside every
  gate. The correction is recorded rather than quietly made true, the same treatment Sprint `1.82`
  gave `vault_doctrine.md` § 20.3.
- ✅ **`code_quality.md` records that region** beside the lint it describes, and points at the
  registered widening.
- ✅ **No section renumbered.** § 24 is appended, so the bound `§ 21`/`§ 22`/`§ 23` citations across
  `documents/`, `DEVELOPMENT_PLAN/` and `src/` Haddock are untouched — the same discipline Sprint
  `0.25` used when appending § 23.

### Validation

1. ✅ `prodbox dev check` exit 0, including `checkDoctrineSectionCitations` over the new bound
   `chaos_hardening_doctrine.md § 24` citations and `checkGeneratedSectionsHarmony` over three files
   that keep `**Generated sections**: none`.
2. ✅ The corrected passage is additive: the original claim is quoted rather than edited, so a reader
   sees what was asserted and where it holds.

### Remaining Work

None on this sprint's surface. The code that makes the widened claim true is Sprint `3.34`; the
broker-side conversion this failure also exposed is Sprint `2.42`. This sprint states the doctrine
they implement and does not depend on either.

**A claim this sprint deliberately does not make.** The lint Sprint `3.34` will add closes drift
between a rendered value and its compiled owner, not correctness of the owner. It would not have
caught this outage: with the owner still saying `443`, the cluster breaks identically. § 24 exists
because the failure was a layer error, and no gate over literals detects a layer error.

## Sprint 0.27: Every Sprint Names What It Touched, And A Gate Keeps It That Way ✅

**Status**: ✅ **Done (2026-08-12)** — Phase `0` own-surface reopen (Standard A) on the plan-document
metadata surface this phase already owns through Sprint `0.21`, which made `**Status**:` values and
cited-source-path existence machine gates and struck `**Referenced by**:` repository-wide. It neither
recloses nor reopens the phase on any other account.
**Implementation**: `src/Prodbox/CheckCode.hs` (`planSprintBlocks`, `sprintBlockMissingFields`,
`checkSprintRequiredFields`, wired into `runGovernedDocChecks`), `test/unit/Main.hs`, and the
back-filled header fields in `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-2-gateway-dns.md`,
`DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`, and
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`.
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated) — this sprint changes plan documentation and
a developer-tooling gate; it moves no production-composition surface. Note that `SourceIdentity`
binds governed documentation, so these edits do move the source-manifest digest a future `proven` row
would bind.
**Independent Validation**: `prodbox dev lint docs` exit 0 on the back-filled plan, and a mutation
exercise that deletes one back-filled field and confirms the gate names the sprint; pure unit cases
over `planSprintBlocks` / `sprintBlockMissingFields`. No cluster, no AWS, no later phase.
**Docs updated**: none under `documents/` — the standards this gate enforces
([Standard H](development_plan_standards.md#h-sprint-status-format),
[Standard G](development_plan_standards.md#g-phase-documentation-requirements)) already say what the
gate now checks, so restating them would be the § 1 duplication
[documentation_standards.md](../documents/documentation_standards.md) forbids.

### Objective

Close the `Pending Removal` row recording that `Done` sprints state closures which cannot be audited
against source, and close it in the shape Sprint `0.21` established: measure, back-fill from
evidence, then make the requirement mechanical so the debt cannot recur.

### The row's measurements were wrong, and correcting them is half the sprint

The row read: **19** `Done` sprints carry no `**Implementation**` line and **39** carry no docs line,
"among the 19 are Sprints `4.50` and `1.62`". Re-measured across all **359** sprint blocks — every
one of which is `Done`, so the population is the whole plan:

| Claim | Recorded | Measured |
|---|---|---|
| No `Implementation` field in any form | 19 | **11** |
| `Implementation` present, heading non-standard | — | **4** |
| No docs field in any form | 39 | **10** |

The 4-row category is the one the original count missed and the reason the headline number was
inflated. Sprint `1.62` writes `**Implementation** (landed):` and the Phase-7 increments write
`**Implementation (Increment A, 2026-07-26)**:`; both name their paths, and both fail a naive
`^\*\*Implementation\*\*:` match. **Sprint `4.50` is not in any of the three categories** — it names
its paths under increment headings — so the row's own example was wrong.

This is recorded rather than quietly corrected because the same mistake was available to this
sprint: the first measurement taken here returned 13/2/10 and put `1.62` in the *missing* column,
for exactly the reason the original row did. The gate's predicate accepts all three heading forms
precisely so it cannot re-report a formatting difference as missing evidence.

### Deliverables

- **Every one of the 359 sprint blocks carries both fields.** Back-filled from each sprint's own
  body, never by inference — the row's own warning is that a fabricated path is worse than a missing
  one, since `checkPlanCitedSourcePaths` will either fail the build on a path that does not exist or
  silently point a reader at the wrong module.
- **Three back-fill categories, each stated as what it is** rather than flattened into a path list:
  - *Named in the sprint's body* (8 sprints) — `2.37`, `2.39`, `7.18`–`7.21` and the docs fields —
    taken verbatim and verified to exist in the worktree.
  - *Resolved from named identifiers* (2 sprints) — `7.22` and `7.23` cite no path at all, so the
    functions they do name were resolved to their defining modules by search. This surfaced a
    finding: `recoverAwsSesPulumiStateFromLiveResources`, which Sprint `7.23` names, is **absent
    from `src/`** — removed by a later sprint that did not record the deletion. The field says so.
  - *Umbrella sprints* (2 sprints) — `7.5` and `7.5.b` have no code of their own; every one of their
    sub-sprints carries its own `Implementation`. Their field points at the sub-sprints and says
    they are containers, which is the honest answer and not the one a path-shaped field invites.
- **A `dev docs check` gate**, `checkSprintRequiredFields`, wired into `runGovernedDocChecks`
  alongside Sprint `0.21`'s status-value and cited-path gates. Its predicate is fenced-block-aware
  and accepts every heading form the plan actually uses.
- **A docs field of `none` is a measurement, not a shrug.** For the 8 sprints where no governed
  document names them, the field records that this was verified by search on a date — distinguishing
  "no doc attributes text to this sprint" from "no doctrine covers the behaviour it changed", which
  are different facts and only the first was checked.

### Validation

1. Every sprint block in `DEVELOPMENT_PLAN/phase-*.md` carries both fields: re-scan returns empty
   for both. ✅
2. **Mutation exercise.** Deleting Sprint `0.26`'s back-filled `**Implementation**` line makes
   `prodbox dev lint docs` exit 1 naming `Sprint 0.26`; restoring it returns exit 0 and the file is
   byte-identical by md5. A gate whose first run finds nothing has had its region drawn to fit the
   code, so this is the evidence that it fires. ✅
3. Eight unit cases over the pure halves, including the two non-standard heading forms that caused
   the original overcount, a fenced-block negative, and a prose line that merely begins with bold. ✅
4. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3382/3382**. ✅

### Remaining Work

None. The row is closed by back-fill plus gate; the ledger entry moves to `Completed` carrying the
corrected measurements.

**What this gate does not do, stated rather than implied.** It checks that a field is *present*, not
that its contents are true. A sprint naming a path it did not touch passes this gate and fails
`checkPlanCitedSourcePaths` only if the path does not exist. Closing that gap would require binding
each sprint to a diff, which this repository's squashed history cannot support — recorded here so
the bound is stated rather than assumed.

## Sprint 0.28: Three Gates Whose Region Was Drawn To Fit The Code ✅

**Status**: ✅ **Done (2026-08-12)** — Phase `0` own-surface reopen (Standard A) on the gate-region
surface this phase owns; Phase `0`'s owner column has named "conversion boundaries and gate regions"
since Sprint `0.25`.
**Implementation**: `src/Prodbox/CheckCode.hs` (`awsCreateVerbs`, `destructivePlanOptionsArms`,
`planOptionsProjectionExemptions`, `scopedPathMissingViolation`, `productionEnvVarRegistry`,
`productionEnvVarNamesIn`, `isEnvironmentVariableName`, `checkProductionEnvVarReads`),
`test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated) — developer tooling only; no
production-composition surface moves. No runtime behaviour changes; the three gates observe more.
**Independent Validation**: four mutation exercises (unregistered env read, registry entry with no
call site, create-verb outside its owner, missing scoped file), each restoring byte-exactly by md5;
nine unit cases. No cluster, no AWS, no later phase.
**Docs updated**: `documents/engineering/lifecycle_reconciliation_doctrine.md` § 3.1 invariants 1 and
4, which state each gate's region and must move with it.

### Objective

Close the `Pending Removal` row recording that three `check-code` gates back claims materially wider
than the region they scan. The row's own framing is the constraint: *"closing the row means deciding
what the registry owes, not lengthening a substring list."*

### Deliverables

- **`awsCreateVerbs` gains the six verbs measured outside it** — `create-volume`,
  `create-receipt-rule-set`, `put-bucket-policy`, `put-object`, `put-public-access-block`,
  `request-service-quota-increase` — each against the owner module measured to contain its
  subprocess literal. The bound is unchanged in kind and only in extent, and the Haddock says so: a
  substring allowlist over a stated region is a
  [§ 22](../documents/engineering/chaos_hardening_doctrine.md) region claim, not a totality proof.
- **`destructivePlanOptionsArms` goes from 2 constructors to 9**, and the region from 3 files to 7.
  A unit case had pinned the table to exactly `["Rke2Delete", "NativeNuke"]` — the two-constructor
  region was an *asserted invariant* while seven destructive constructors dispatched outside it, the
  same shape Sprint `4.76` found in the `nuke` sweep. It carries a Standard-C correction.
- **Both scoped gates fail closed on a missing file.** Each answered a missing scoped path with
  `pure []`, so a rename silently emptied the gate's region while the gate kept passing — the
  fail-open shape this doctrine names, applied to the gates themselves.
- **`checkEnvVarConfigReads` is joined by a registry rather than widened.** The row asks for the
  registry, and a whole-file `lookupEnv` ban could not have been extended to
  `src/Prodbox/CLI/Rke2.hs` anyway: its reads are legitimate production reads that do not reach
  Tier-0 config, so adding the file would have failed the gate rather than described it. The new
  `checkProductionEnvVarReads` is a **bijection** over all of `src/` and `app/`, in the
  legacy-escape-registry idiom: an unregistered read fails, a read outside its registered owner
  fails, and a registry entry with no surviving call site fails.

### What the measurement found that neither document recorded

The ledger row named four unguarded `PRODBOX_*` reads in `src/Prodbox/CLI/Rke2.hs`, and `CLAUDE.md`
names the same four. The measured set is **12** non-`PRODBOX_TEST_` names:

| Where | Count | Recorded before |
|---|---|---|
| `src/Prodbox/CLI/Rke2.hs` | 5 (the four named, with the LB-IP pair counted as one) | yes |
| `src/Prodbox/CLI/Interactive.hs` | 1 (`PRODBOX_ALLOW_NON_TTY_INTERACTIVE`) | yes |
| `src/Prodbox/CLI/Nuke.hs` | 1 (`PRODBOX_NUKE_PLAN`) | **no** |
| `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/AwsSesStack.hs` | 5 (`PRODBOX_PULUMI_AWS_*`) | **no** |

Seven names that neither the ledger row nor `CLAUDE.md` mentions. None reaches Tier-0 resolution —
the five `PRODBOX_PULUMI_AWS_*` names carry an already-resolved credential into the `pulumi`
subprocess environment, which is transport rather than configuration — so the standing Tier-0 claim
survives. What does not survive is the *inventory*, and the registry replaces it with something that
cannot silently fall out of date.

### The gate's first run produced one false positive, recorded rather than patched away

It flagged `"PRODBOX_ID="` in `src/Prodbox/CLI/Rke2.hs`. That is a `--dry-run` plan **key** rendered
as `KEY=value` and never passed to `lookupEnv`. The exclusion is `isEnvironmentVariableName`, a
property of environment names — POSIX forbids `=` in one — rather than a path exemption or a
trailing-`=` heuristic, so it stays true for a plan key nobody has written yet.

Widening `destructivePlanOptionsArms` produced a second: `commandPrerequisites` in
`src/Prodbox/Native.hs` binds `AwsTeardown _ _`, and it is a pure projection from a command to its
`PrerequisiteId`s with no options to honour. It is exempted as a **`(path, constructor)` pair**, in
Sprint `4.66`'s idiom. The pair is the unit because a bare constructor exemption would also excuse
the real dispatch site in `src/Prodbox/Aws.hs` — which is now inside the region and binds properly, a
fact a unit case asserts directly.

### Validation

1. **Four mutation exercises**, each restoring byte-exactly by md5: renaming a registered env read to
   an unregistered name fires the unregistered arm; adding a registry entry nothing reads fires the
   orphan arm; a `create-volume` literal in a non-owner module fires the create-site gate; moving a
   scoped file out of the worktree fires the new fail-closed arm. A gate whose first run finds
   nothing has had its region drawn to fit the code. ✅
2. Nine unit cases covering the six new verbs, the IAM-projection narrowing, the nine destructive
   constructors, the plan-key exclusion, the `PRODBOX_TEST_` exclusion, owner resolution, and the
   five-name Rke2 count. ✅
3. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3391/3391**. ✅

### Remaining Work

None on the row. **Two bounds are stated rather than implied**, because widening a region is not the
same as closing a class:

- `awsCreateVerbs` is still a substring allowlist. A create verb nobody has thought of is still
  invisible to it, and § 3.1 invariant 1's totality claim still rests on the registry, not on this
  lint. What changed is that the six verbs *already known* to be outside it no longer are.
- `checkProductionEnvVarReads` proves every `PRODBOX_*` read is registered and owned. It does not
  prove the registry's *reasons* are true — that `PRODBOX_PULUMI_AWS_*` is transport rather than
  configuration is an argument in a Haddock, not a property a gate can check.

## Sprint 0.29: The Tier-0 Witness Closes The Round-Tripping Hand Edit ✅

**Status**: ✅ **Done (2026-08-12)** — Phase `0` own-surface reopen (Standard A) on the Tier-0
config-gate surface Sprint `0.24` opened. It closes that sprint's own recorded residual.
**Implementation**: `src/Prodbox/Config/Tier0.hs` (`tier0RecordWitness`, `tier0WitnessPrefix`,
`stampTier0Witness`, and the stamping step inside `renderProjectConfigDhall`), `test/unit/Main.hs`,
`test/unit/Tier0PlanAssert.hs`.
**Blocked by**: none.
**Deployment qualification**: **pending, and this sprint moves the surface.** Stamping a witness
changes the content of **every** generated `prodbox.dhall`, which is a Standard-P
generated-config-identity change by the enumeration in
[Standard P](development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).
Both substrate rows are already `pending`, so nothing is invalidated, but a future qualification run
must bind the post-`0.29` generated-config identity and may not carry forward one recorded before it.
This consequence is why Sprint `0.24` declined to fold the work in: its declared scope was a
developer-tooling check touching no production-composition surface, and this is not that.
**Independent Validation**: the mutation exercise below on the live binary-sibling
`prodbox.dhall` — no cluster, no AWS, no later phase — plus pure unit cases over the witness
algebra. `prodbox dev check` exit 0; `prodbox test unit` exit 0.
**Docs updated**: `documents/engineering/config_doctrine.md` (the Tier-0 drift-gate bound).

### Objective

Close the `Pending Removal` row recording that a hand edit to a binary-sibling `prodbox.dhall`
**primitive that round-trips unchanged** is undetected.

### Why no text comparison could have closed it

Sprint `0.24`'s gate decodes the sibling file, re-renders the decoded record through the one
canonical generator, and compares text. Its first mutation exercise proved the bound: a re-typed
`route53.zone_id` decodes to that value and re-renders to that value, so **the edited file *is* the
generator's output for the record it carries**. There is nothing for the comparison to disagree with
— the file is self-consistent. The row's own note says the class needs "a generator-stamped witness
over the record, for which the Tier-0 `witness` field already exists".

### Deliverables

- **`renderProjectConfigDhall` stamps the record's own witness before rendering.** Because both
  body renderers inject the whole `ProdboxProjectConfig`, stamping upstream reaches the guarded and
  the plain body without touching either.
- **The digest covers `parameters` and `context` and not `witness`.** That is forced rather than
  chosen: a witness over a record containing itself has no fixed point. It also makes
  `stampTier0Witness` idempotent, which a unit case pins.
- **No new gate.** Stamping makes the *existing* Sprint-`0.24` comparison catch the class: after a
  hand edit the file holds the **old** witness beside the **new** primitive, the gate re-renders the
  decoded record and stamps a witness computed from the edited content, and the two disagree. The
  right fix here was a field that cannot be edited consistently by hand, not a second gate.
- **A versioned prefix**, `prodbox-tier0-witness-v1:`, so a later scheme appends rather than silently
  changing what an identically-shaped string means.

### The round-trip property is restated truthfully, not preserved by sleight of hand

Five assertions across three test modules asserted `decode ∘ render == id`. That is no longer the
property; the property is `decode ∘ render == stampTier0Witness`, and the cases now say so. Writing
it this way keeps the stamping visible in the test rather than hiding it behind a fixture that
already carries the right witness — and the two round-trip cases additionally assert that
`parameters` and `context` are unchanged, so "identity outside the witness" stays pinned rather than
being absorbed into the new wording.

### Validation

1. **Mutation exercise on the live sibling config, and it is the acceptance criterion.** With
   `.build/prodbox.dhall` freshly generated and `dev check` clean, hand-editing `route53.zone_id` to
   a value that decodes and re-renders unchanged makes `prodbox dev check` exit 1 with
   `has drifted from the generator's canonical rendering at line 4121, field `witness``. Restoring
   the file returns exit 0 and it is byte-identical by md5. Before this sprint the identical edit
   left the gate clean. ✅
2. Unit cases: stamping is idempotent and ignores a pre-existing witness; the value carries its
   scheme prefix; a changed primitive changes the witness; a record carrying the pre-edit witness is
   detectably stale while rendering identically to the correctly-stamped one; and the stamp changes
   no field but `witness`. ✅
3. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3395/3395**. ✅

### Remaining Work

None on the row. **The bound is stated rather than implied**: an operator who edits a primitive *and*
recomputes the witness defeats this, exactly as they would defeat any in-file stamp. What it removes
is the *silent* edit — the one that leaves a self-consistent file and no evidence — not the
deliberate one. Closing that would require a signature over a key the file does not carry, which is
a different sprint on a different surface.

A second consequence worth stating: the gate now fails on any `prodbox.dhall` generated **before**
this sprint, because those carry `witness = []`. That is correct behaviour and not a migration
hazard — the file is git-ignored, binary-owned, and regenerated by `prodbox config generate` after
removing it — but `config generate` is idempotent and leaves an existing file untouched, so the
remedy is `rm` then generate rather than generate alone.

## Documentation Requirements

**Engineering docs to create/update:**

- ✅ Sprint `0.29`: `documents/engineering/config_doctrine.md` - the Tier-0 drift gate's bound, and
  the generator-stamped witness that closes the round-tripping hand-edit class.
- ✅ Sprint `0.28`: `documents/engineering/lifecycle_reconciliation_doctrine.md` - § 3.1 invariants 1
  and 4 record each gate's region, so they move when the region does.
- ✅ Sprint `0.26`: `documents/engineering/chaos_hardening_doctrine.md` - new § 24 "An observation
  has a layer" (SSoT for the observation-layer rule) and a § 12 ledger row. Appended, so no bound
  citation moves.
- ✅ Sprint `0.26`: `documents/engineering/helm_chart_platform_doctrine.md` - the probe/route
  single-source rule's enforcement region is recorded in place (Standard C); the claim as written
  was wider than the region enforces.
- ✅ Sprint `0.26`: `documents/engineering/code_quality.md` - the chart forbidden-literal lint's
  region, and the fact that no gate reads a chart `networkpolicy.yaml` for content.
- ✅ Sprint `0.25`: `documents/engineering/chaos_hardening_doctrine.md` - new § 23 "Conversions —
  where the moves stop" (SSoT for the conversion-boundary rule); § 22 fourth honest consequence and
  Ring-2 cell; § 21's sufficiency claim corrected in place; a § 12 ledger row.
- ✅ Sprint `0.25`: `documents/engineering/resource_scaling_doctrine.md` - § 2C gains "The region of
  Ring 2" (SSoT for the ring-region rule, per § 22's delegation of the ring vocabulary).
- ✅ Sprint `0.25`: `documents/engineering/code_quality.md`, `config_doctrine.md`,
  `unit_testing_policy.md`, `integration_fixture_doctrine.md`, `pure_fp_standards.md` (new § 2.3a),
  `haskell_code_guide.md`, `bootstrap_readiness_doctrine.md` - each inherits the two rules by
  reference rather than restatement (documentation_standards.md § 5, non-duplication).
- ✅ `documents/documentation_standards.md` - § 3 header block reduced to three fields; § 4
  `Bidirectional Links` replaced by `Back-Links Are Derived, Never Authored`; the § 1 and § 10
  co-owned statement reworded (SSoT).
- ✅ `documents/engineering/README.md` - the same co-owned statement, per § 10's linked-dependents
  list.
- ✅ `documents/engineering/code_quality.md` - the generated-sections metadata-block sentence names
  `**Supersedes**` rather than the struck field.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Record the struck field in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) and the Sprint `0.21` row in
  [README.md](README.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [the engineering doctrine docs](../documents/engineering/README.md)
