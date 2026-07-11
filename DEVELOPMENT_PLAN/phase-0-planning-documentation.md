# Phase 0: Planning and Documentation Topology for Haskell Rewrite

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[substrates.md](substrates.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md)
**Generated sections**: none

> **Purpose**: Define the plan-ownership baseline for the Haskell rewrite so status, sequencing,
> Python-removal work, and CLI doctrine adoption have one canonical home.

## Phase Status

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
- `README.md` and `00-overview.md` update the Phase `1` sprint-range strings (`Sprints
  1.6–1.23` → `Sprints 1.6–1.26`), add Sprint 0.3 to the Phase Overview entry for
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
  [Output Rules](../documents/engineering/streaming_doctrine.md#output-rules) and
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
- Revision passes on `DEVELOPMENT_PLAN/README.md` (Closure Status reopen paragraph,
  Phase Overview table updates for Phases 0/1/2/3), `00-overview.md` (BootConfig /
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
  link discipline).

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
- The plan suite — `DEVELOPMENT_PLAN/README.md` (new dated 2026-06-15 Closure Status entry
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
   files, and the legacy ledger.
5. A grep replay confirms no "Option A/B/C" Pulumi ladder and no "long-lived SSE" wording
   survives in any governed doc, the 2026-06-15 Closure Status reads as a refinement (not a phase
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

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [the engineering doctrine docs](../documents/engineering/README.md)
