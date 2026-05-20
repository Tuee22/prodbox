# Phase 0: Planning and Documentation Topology for Haskell Rewrite

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[substrates.md](substrates.md),
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)

> **Purpose**: Define the plan-ownership baseline for the Haskell rewrite so status, sequencing,
> Python-removal work, and CLI doctrine adoption have one canonical home.

## Phase Status

✅ **Done** — Sprint 0.1 (canonical plan suite for the Haskell rewrite) is `Done`, and the
Phase-0 doctrine-governance reopens scheduled by Sprints `0.2`, `0.3`, `0.4`, `0.5`, and `0.6`
are also now `Done`. Those sprints adopted
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) as the authoritative CLI doctrine, aligned the
governed docs and plan suite with that doctrine, scheduled every currently known code-level
adoption gap onto explicit downstream sprints under Phases `1`–`4` per
[development_plan_standards.md](development_plan_standards.md) rule L, reopened Phase `4`
through Sprint `4.8` to harden the user-visible `prodbox rke2 delete --yes` success-summary
contract, and (Sprint 0.6) introduced the substrate doctrine into the canonical phase model:
one canonical test suite that runs against substrates (home local + AWS), renamed
phase-5 to `phase-5-canonical-test-suite.md`, renamed phase-7 to
`phase-7-aws-substrate-foundations.md`, added [substrates.md](substrates.md) as the
authoritative substrate inventory, and added phase-8 for operator-invited email authentication
via Keycloak + AWS SES. Phase `0` is therefore re-closed, and the downstream implementation
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
extends that governance contract again for the `prodbox rke2 delete --yes` success-summary
surface, scheduling hermetic suppression of benign upstream uninstall chatter plus the governed
documentation updates required by
[../documents/documentation_standards.md](../documents/documentation_standards.md).

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

1. `prodbox check-code`

### Remaining Work

None.

## Sprint 0.2: Adopt HASKELL_CLI_TOOL.md as Governed CLI Doctrine ✅

**Status**: Done
**Implementation**: `HASKELL_CLI_TOOL.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`,
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

Promote [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) into the governance contract so it is the
authoritative CLI doctrine for the repository, align the development plan suite and governed
engineering docs with the doctrine, eliminate contradictions, and schedule the downstream code
adoption through declared phase reopens.

### Deliverables

- `HASKELL_CLI_TOOL.md` carries the standard `**Status**` / `**Supersedes**` / `**Referenced by**`
  metadata block and is reachable from every plan document and root pointer.
- `development_plan_standards.md` defines the CLI Doctrine Alignment rule (standards rule L) and
  requires phase docs to cite doctrine sections by name when scheduling adoption work.
- `documents/documentation_standards.md` documents the six Generated Sections requirements named
  by the doctrine: marker syntax per file type with literal `<prodbox>:<key>:start|end`
  examples, an authoritative pointer to the in-code `GeneratedSectionRule` registry, a
  "How to regenerate" instruction naming `prodbox docs generate`, a per-file
  `**Generated sections**: <key1>, <key2>` (or `none`) metadata field with a lint contract, a
  five-step extension protocol, and a "fully generated, do-not-hand-edit" rule.
- Governed engineering docs that overlap with the doctrine — `code_quality.md`,
  `unit_testing_policy.md`, `prerequisite_doctrine.md`, `cli_command_surface.md`,
  `haskell_code_guide.md`, `refactoring_patterns.md`, `effect_interpreter.md` — cite the
  doctrine sections they implement, defer to the doctrine on shared topics, and retain only
  project-specific elaborations.
- Root pointers in `README.md`, `AGENTS.md`, and `CLAUDE.md` link to `HASKELL_CLI_TOOL.md`
  alongside the existing `DEVELOPMENT_PLAN/README.md` link.
- `DEVELOPMENT_PLAN/README.md` and `DEVELOPMENT_PLAN/00-overview.md` declare Phases 0–4
  reopened for doctrine adoption, enumerate the new sprints in each (Phase 1 Sprints
  1.6–1.22 and Phase 2 Sprints 2.9–2.15, where 1.17–1.22 and 2.15 close the doctrine gaps
  identified by the HASKELL_CLI_TOOL.md adoption audit), and call out the surfaces in
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

1. `prodbox check-code` passes after all Sprint 0.2 documentation edits.
2. `documents/documentation_standards.md` covers every one of the six doctrine-mandated
   Generated Sections elements; a diff against the doctrine's "Project-level documentation
   standards" subsection shows no missing item.
3. Each governed engineering doc named above either cites a doctrine section by name or shrinks
   to a doctrine pointer.
4. Each reopened phase document declares its new sprints per standards rule H, citing the
   doctrine sections they implement.
5. Root `README.md`, `AGENTS.md`, and `CLAUDE.md` link to `HASKELL_CLI_TOOL.md`.

### Remaining Work

None.

## Sprint 0.3: Audit-Driven Doctrine-Gap Scheduling ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`,
`DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`,
`DEVELOPMENT_PLAN/phase-2-gateway-dns.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: every file listed above.

### Objective

Schedule the residual [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) items surfaced by the
May 2026 doctrine-vs-plan audit so every doctrine-prescribed behavior that the worktree did
not yet honor was owned by an explicit sprint block, per
[development_plan_standards.md](development_plan_standards.md) rule L.

### Deliverables

- Phase `1` sprint range extends to **Sprint 1.26**:
  - **Sprint 1.24: Durable CLI Documentation Artifacts** schedules the Markdown command
    reference, manpages, and shell completion scripts derived from the `CommandSpec`
    registry per [../HASKELL_CLI_TOOL.md → Automatically Generated
    Documentation](../HASKELL_CLI_TOOL.md) §269–318 and `The Architecture` summary
    §2349–2356. HTML output is recorded as a doctrine-aware deferral until a consumer enters
    scope.
  - **Sprint 1.25: Parser-Test Category via `execParserPure`** schedules the
    `argv → Command` parser-test category per [../HASKELL_CLI_TOOL.md → Parser
    Tests](../HASKELL_CLI_TOOL.md) §2116–2138 in addition to the rendered-output golden
    tests already owned by Sprint 1.6.
  - **Sprint 1.26: Error Rendering Boundary Discipline** schedules `renderError :: AppError
    -> Text` at the CLI boundary plus hlint rules refusing `print`, `exitFailure`, and
    direct terminal formatting in non-boundary code, per [../HASKELL_CLI_TOOL.md → Error
    Handling](../HASKELL_CLI_TOOL.md) §815–831.
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
    records and frozen `./types.dhall` / `./defaults.dhall` imports (doctrine §1551–1574).
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

1. `prodbox check-code` passes after all Sprint 0.3 documentation edits.
2. Each new sprint block (0.3, 1.24, 1.25, 1.26) follows the rule H sprint format
   (Status / Implementation / Docs to update / Objective / Deliverables / Validation).
3. Each new sprint cites the [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) section it
   implements by section heading, per standards rule L.
4. A manual walk of the 11 audit findings against the updated plan suite shows every
   finding resolved to either a named sprint deliverable or an explicit doctrine-aware
   deferral.
5. Mermaid render pass (standards rule K) is a no-op — Sprint 0.3 introduces no
   diagrams.

### Remaining Work

None.

## Sprint 0.4: Round-3 Doctrine Adoption Closure ✅

**Status**: Done
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

Schedule the residual [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) items surfaced by the
May 12, 2026 round-3 doctrine-vs-plan audit so every doctrine-prescribed behavior that the
worktree did not yet honor was owned by an explicit sprint block, per
[development_plan_standards.md](development_plan_standards.md) rule L. The audit identified
fifteen doctrine prescriptions returning zero hits across the prior plan suite plus five
thinly-scheduled items; this sprint bound them through one new Phase `1` sprint (1.27) and
thirteen deliverable extensions to existing sprints.

### Deliverables

- New **Sprint 1.27: Toolchain Pin Declarations and Library-First Layout** in
  `phase-1-runtime-cli-aws-foundations.md` owns the cabal-manifest declarations
  `tested-with: ghc ==9.14.1` and `with-compiler: ghc-9.14.1`, the literal
  `Cabal 3.16.1.0` version pin, and the library-first / thin-`Main.hs` layout audit per
  [../HASKELL_CLI_TOOL.md → Toolchain pinning](../HASKELL_CLI_TOOL.md) §70–84 and
  `Project Structure` §86–115.
- Phase `1` sprint deliverable extensions (no new sprints beyond 1.27):
  - Sprint 1.6 binds the `CommandSpec` and `OptionSpec` record fields
    (`name` / `summary` / `description` / `children` / `options` / `examples` and
    `longName` / `shortName` / `metavar` / `description` / `required`) per
    [../HASKELL_CLI_TOOL.md → Automatically Generated
    Documentation](../HASKELL_CLI_TOOL.md) §283–304, and binds the
    daemon-as-typed-`Command` dispatch pattern per
    [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Daemon as
    Command](../HASKELL_CLI_TOOL.md) §1156–1196.
  - Sprint 1.8 names `callProcess`, `readCreateProcess`, and direct
    `System.Process` smart constructors as forbidden subprocess primitives in the
    `prodbox lint files` rules and the `.hlint.yaml` negative-space symbol set per
    [../HASKELL_CLI_TOOL.md → Architecture → Subprocesses as Typed
    Values](../HASKELL_CLI_TOOL.md) §531.
  - Sprint 1.10 binds the twelve minimum `fourmolu.yaml` settings (`indentation`,
    `column-limit`, `function-arrows`, `comma-style`, `import-export-style`,
    `indent-wheres`, `record-brace-space`, `newlines-between-decls`, `haddock-style`,
    `let-style`, `in-style`, `unicode`, `respectful`) per
    [../HASKELL_CLI_TOOL.md → Lint, Format, and Code-Quality Stack → Pinned
    fourmolu.yaml](../HASKELL_CLI_TOOL.md) §1834–1860.
  - Sprint 1.11 enumerates the canonical property-test invariants
    `decode . encode == id`, `render is deterministic`, and `parser roundtrips` as
    required `prodbox-unit` categories per
    [../HASKELL_CLI_TOOL.md → Test Categories → Property
    Tests](../HASKELL_CLI_TOOL.md) §2179–2188.
  - Sprint 1.12 binds the service-error newtype inventory (`MinIOError`,
    `RedisError`, `PgError` each wrapping `ServiceError` and each carrying an
    `AsServiceError` instance) per
    [../HASKELL_CLI_TOOL.md → Capability Classes and Service
    Errors](../HASKELL_CLI_TOOL.md) §867–890.
  - Sprint 1.14 binds the daemon `AppError` record shape
    `data AppError = AppError { errorKind :: ErrorKind, errorMsg :: Text, errorCause :: Maybe SomeException }`
    per [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Error
    Handling](../HASKELL_CLI_TOOL.md) §1300–1340.
  - Sprint 1.15 binds the `boundedResourceName`, `sanitizeResourceName`, and
    `hashSuffix` signatures including the DNS-1123-label and 63-character
    constraints per
    [../HASKELL_CLI_TOOL.md → Smart Constructors for Paired
    Resources](../HASKELL_CLI_TOOL.md) §565–630.
  - Sprint 1.21 enumerates the forbidden renderer inputs (timestamps, random IDs,
    locale-dependent ordering, terminal-width-dependent wrapping,
    environment-dependent paths) the determinism contract refuses, per
    [../HASKELL_CLI_TOOL.md → Generated Artifacts → Renderer
    Determinism](../HASKELL_CLI_TOOL.md) §459–470.
- Phase `2` sprint deliverable extensions (no new sprints):
  - Sprint 2.9 enumerates the structured-concurrency primitive set as the closed
    set worker loops may use: `withAsync`, `race`, `concurrently`,
    `replicateConcurrently`, per
    [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Lifecycle
    → Structured Concurrency](../HASKELL_CLI_TOOL.md) §1313–1324.
  - Sprint 2.11 adds `fsnotify`, `inotify`, and `mtime` polling to the forbidden
    reload-trigger set per
    [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Configuration
    → Reload Trigger](../HASKELL_CLI_TOOL.md) §1491–1500, binds the typed Dhall
    field `schemaVersion : Natural` plus the mismatch-as-parse-failure semantic per
    `Configuration → Schema Versioning` §1530–1538, and binds the eight-step reload
    procedure step-by-step per `Configuration → Reload Procedure` §1502–1530.
  - Sprint 2.12 binds the typed field helper
    `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` and the
    convenience wrappers `logStructured`, `logDebug`, `logInfo`, `logWarn`,
    `logError` per
    [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary →
    Logging](../HASKELL_CLI_TOOL.md) §1370–1410.
  - Sprint 2.13 binds the production-no-op / test-injected hook contract pattern
    per [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Test
    Hooks](../HASKELL_CLI_TOOL.md) §1284–1300.
  - Sprint 2.14 captures the `/healthz`, `/readyz`, and `/metrics` response shapes
    as golden tests in the `prodbox-daemon-lifecycle` stanza (200 alive for
    `/healthz`; 200 ready / 503 draining for `/readyz`; Prometheus-exposition
    format for `/metrics`) per
    [../HASKELL_CLI_TOOL.md → Test Categories → Golden
    Tests](../HASKELL_CLI_TOOL.md) §2243 and `Long-Running Daemons in the Same
    Binary → Health Endpoints`.
- Phase `3` sprint deliverable extension (no new sprints):
  - Sprint 3.10 names `--force` and `--reinstall` flags as forbidden on the chart
    reconciler surface and names sister commands `install`, `upgrade`, `repair`,
    `force-install` as forbidden per
    [../HASKELL_CLI_TOOL.md → Reconcilers → Forbidden
    Patterns](../HASKELL_CLI_TOOL.md) §1781–1803.
- Phase `4` sprint deliverable extension (no new sprints):
  - Sprint 4.5 applies the same forbidden-flag and sister-command discipline to the
    lifecycle reconciler: no `--force`, no `--reinstall`, no sister commands. The completed
    one-cycle `prodbox rke2 install` alias is retired after the compatibility window, and the
    name is now rejected as a forbidden sister command. Doctrine
    [../HASKELL_CLI_TOOL.md → Reconcilers → Forbidden
    Patterns](../HASKELL_CLI_TOOL.md) §1781–1803.
- Cross-reference updates: `DEVELOPMENT_PLAN/README.md`,
  `DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`
  record the reopen, the new Sprint 1.27, and the doctrine identifiers bound by
  the round-3 extensions.
- `DEVELOPMENT_PLAN/00-overview.md` adds an explicit note that the doctrine's
  cross-language type-bridge full-file generation surface
  ([../HASKELL_CLI_TOOL.md → Generated Artifacts → Two categories of
  generation → Full generation](../HASKELL_CLI_TOOL.md) §395–400) is intentionally
  empty in the supported worktree today because no non-Haskell consumer exists;
  the registry will be populated when one does. Composes with Sprint 1.23's
  existing deferral.
- `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` records that Sprint 0.4
  introduced no new pending-removal scope. The round-3 audit bindings were
  green-field plan-text additions, not deprecations; the implementation residue
  they scheduled has now closed through the downstream owning sprints.

### Validation

1. `prodbox check-code` passes after all Sprint 0.4 documentation edits.
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
4. Each new deliverable cites the [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)
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
  [../HASKELL_CLI_TOOL.md → Output Rules](../HASKELL_CLI_TOOL.md#output-rules) and
  [../HASKELL_CLI_TOOL.md → Reconcilers: Idempotent Mutation as a Single
  Command](../HASKELL_CLI_TOOL.md#reconcilers-idempotent-mutation-as-a-single-command).
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

1. `prodbox check-code` passes after the Sprint 0.5 plan edits.
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

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Root guidance docs (`README.md`, `AGENTS.md`, `CLAUDE.md`) link to
  [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) as the architectural doctrine.
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
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`HASKELL_CLI_TOOL.md`, `documents/engineering/unit_testing_policy.md`
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
- `HASKELL_CLI_TOOL.md` and `documents/engineering/unit_testing_policy.md` are updated to
  cite the new substrate doctrine and to use the renamed phase paths.

### Validation

1. `prodbox check-code`.
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

- `HASKELL_CLI_TOOL.md` cross-references the renamed `phase-5-canonical-test-suite.md` and
  `phase-7-aws-substrate-foundations.md` paths plus the new `phase-8-email-invite-auth.md`
  and `substrates.md` files.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)
