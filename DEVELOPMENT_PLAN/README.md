# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md),
[../documents/engineering/README.md](../documents/engineering/README.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[substrates.md](substrates.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Closure Status

Phase `0` reopened through Sprints `0.2`–`0.7` (see
[phase-0-planning-documentation.md](phase-0-planning-documentation.md)) to adopt
[the engineering doctrine docs](../documents/engineering/README.md) as the canonical CLI doctrine, align the
governed docs and plan suite to that doctrine, schedule every currently known code-level
adoption gap onto explicit downstream sprints, and (Sprint `0.7`, May 20, 2026) add the
LLM/automation guardrails so every operator-interactive entry point refuses to run on a
non-TTY stdin and points the caller at the automation equivalent. That Phase-0
doctrine-governance work is now `Done`. Phases `1` through `4` were **reopened** for the
scheduled implementation work named below and are now reclosed. Sprint 0.3 extended the
doctrine-adoption scope with the residual items surfaced by the May 2026 doctrine-vs-plan
audit, scheduling them through new Phase `1` sprints (1.24–1.26) and through deliverable
extensions to existing planned Phase `1` and Phase `2` sprints. Sprint 0.4 extended the
doctrine-adoption scope again with the residual items surfaced by the May 12, 2026 round-3
doctrine-vs-plan audit, scheduling them through one new Phase `1` sprint (1.27) and through
deliverable extensions to existing planned Phase `1`, Phase `2`, Phase `3`, and Phase `4`
sprints. Sprint 0.5 reopened Phase `4` through Sprint `4.8` to harden the
`prodbox rke2 delete --yes` success-summary contract; Sprint
`4.8` is now `Done`, the lifecycle-local quiet path captures the upstream uninstall output, the
expanded `isIgnorableRke2DeleteNoiseLine` filter classifies inotify warnings such as
`Failed to allocate directory watch: Too many open files` as benign noise, and the integration
suite proves both the hermetic success contract and the summarized failure path. Sprint 1.2
was revised May 20, 2026 to replace the external `dhall-to-json` subprocess decode bridge
with in-process decoding through the native Haskell `dhall` library
(`Dhall.inputFile auto`); the `toolDhall` / `tool_dhall` external-tool prerequisite, the
matching prerequisite-registry assertion, and the `FromJSON` / `ToJSON` derivations on the
settings record types are removed from the supported path.
Phase `5` briefly reopened
through Sprint `5.5` to add the missing public HTTP listener that redirects port `80` to the
canonical HTTPS edge, and that redirect follow-up is now `Done` after the May 13, 2026
aggregate validation. Phases `5` and `6` are `Done` on their owned surfaces (public-edge
proof, clean-room rerun contract). Phase `7` is `Done` on its **legacy** owned scope
(Sprints `7.1`–`7.4`: interactive onboarding, AWS IAM management, quota automation, and the
temporary-admin-credential validation harness) **and** has reopened for AWS-substrate parity:
Sprint `7.5` is `Active` (sub-sprints `7.5.a`/`7.5.b.*`/`7.5.b.iii`/`7.5.c.i`–`7.5.c.iv`/
`7.5.c.v.b`/`7.5.c.v.c`/`7.5.c.v.d`/`7.5.c.v.e` are `Done` on their code-owned surfaces;
Sprint `7.5.c.v.f` is `Done` on its code-owned surface (May 21, 2026: substrate-aware
`prodbox host public-edge --substrate {home-local,aws}` plus stderr breadcrumbs in
`runNativeValidation` that make silent exit structurally impossible); the live
`--substrate aws` re-run rolls up into Sprint `7.5.c.v`); Sprints `7.6` (orphan-safety
refuse-path + auto-destroy postflight) and `7.7` (generalized `aws teardown` +
`PulumiResiduePolicy` ADT + harness teardown bug closure + admin-credential prompt UX)
are both `Done` (May 19, 2026). Phase `4` reopened May 21, 2026 to schedule Sprints
`4.10`–`4.15`: code frameworks for Sprints `4.10`–`4.13` landed the same day
(long-lived Pulumi backend decouple, lifecycle predicate library + `--cascade`,
K8s drain phase, `prodbox nuke` scaffold), Sprint `4.14`
(operator vocabulary contract enforcement) closed the same day —
every `Sprint <digit>` leak in operator-facing surfaces is removed
and a new `checkOperatorVocabulary` scan refuses regressions — and
Sprint `4.15` (cascade tolerates absent cluster) closed the same
day with a live verification on this host: `prodbox rke2 delete
--cascade --yes` now skips the K8s drain phase cleanly when the
cluster is already gone and proceeds to the per-run Pulumi destroys.
The live AwsSesStack admin-credential switch / live cascade
exercise against a running cluster / live `nuke` exercise are
scheduled as remaining work for Sprints `4.10`–`4.13`. Phase `8` is `Active` on Sprints
`8.5`–`8.6`. The doctrine-adoption handoff is closed; remaining open work is
substrate-parity live validation (Sprint `7.5.c.v`), the residual Phase `4` live closures
for Sprints `4.10`–`4.13`, and live Keycloak invite OIDC closure (Sprint `8.5`).

Reopened sprints by phase:

- Phase 0 — **Sprints 0.2, 0.3, 0.4, 0.5, 0.6**: Sprint 0.2 adopts the engineering doctrine docs as governed CLI
  doctrine. Updates `documents/documentation_standards.md` with the six Generated Sections
  requirements, retags governed engineering docs as doctrine pointers, and threads doctrine
  cross-references through the plan suite and root guidance. Sprint 0.3 schedules the
  residual doctrine items surfaced by the May 2026 audit: durable CLI documentation
  artifacts (Markdown command reference, manpages, shell completions), the `execParserPure`
  parser-test category, the `renderError` error-rendering boundary discipline, per-command
  `CommandSpec` `Example` entries, the `cabal format` temp-file round-trip byte-equality
  compare, the default 30 s drain deadline plus explicit `bracketOnError`, the
  `envMetrics :: MetricsRegistry` typed daemon `Env` field, the STM broadcast channel for
  `LiveConfig` subscribers, the prescribed on-disk Dhall file shape, and the daemon
  log-level refresh from `LiveConfig` on every hot reload. Sprint 0.4 schedules the
  residual doctrine items surfaced by the May 12, 2026 round-3 audit: cabal-manifest
  toolchain pin declarations (`tested-with: ghc ==9.14.1`, `with-compiler: ghc-9.14.1`,
  the `Cabal 3.16.1.0` reference), library-first / thin-`Main.hs` layout, the
  `CommandSpec` / `OptionSpec` record-field bindings plus daemon-as-typed-`Command`
  dispatch, forbidden subprocess primitives (`callProcess`, `readCreateProcess`,
  direct `System.Process` constructors), the twelve minimum `fourmolu.yaml` settings,
  the canonical property-test invariants (`decode . encode == id`,
  `render is deterministic`, `parser roundtrips`), the service-error newtype inventory
  (`MinIOError`, `RedisError`, `PgError` wrapping `ServiceError`), the daemon
  `AppError` record shape (`errorKind`, `errorMsg`, `errorCause :: Maybe SomeException`),
  the naming-helper signatures with DNS-1123 / 63-character constraints, the enumerated
  forbidden renderer inputs, the structured-concurrency primitive set
  (`withAsync` / `race` / `concurrently` / `replicateConcurrently`), the forbidden
  reload triggers (`fsnotify`, `inotify`, `mtime` polling) plus typed
  `schemaVersion : Natural` Dhall field and eight-step reload procedure, typed
  logging field helpers (`field`, `logStructured`, `logDebug`, `logInfo`,
  `logWarn`, `logError`), the production-no-op / test-injected hook contract,
  the health-endpoint response shapes captured as golden tests, and the forbidden
  reconciler flags and sister commands (`--force`, `--reinstall`, `install`,
  `upgrade`, `repair`, `force-install`). Sprint 0.5 schedules the remaining
  `prodbox rke2 delete --yes` success-path output residue: a new Phase `4` sprint
  hardens hermetic success summaries, tracks the leak in the cleanup ledger, and names the
  governed documentation updates required by `documents/documentation_standards.md`. Sprint
  0.6 introduces the substrate doctrine into the canonical phase model, renames
  `phase-5-public-host-validation.md` → `phase-5-canonical-test-suite.md` and
  `phase-7-aws-iam-quota-automation.md` → `phase-7-aws-substrate-foundations.md`, adds
  [substrates.md](substrates.md), and makes substrate provision/teardown a per-substrate
  concern separate from suite content.
- Phase 1 — **Sprints 1.6–1.27**: `CommandSpec` source-of-truth split; `Plan` / `apply`
  discipline with `--dry-run`; `Subprocess` ADT formalization; prerequisite registry
  remedy-hint contract; lint, generated-section, and forbidden-path stack alignment;
  `hspec` → `tasty` test-stanza migration; capability classes plus `AsServiceError`;
  `RetryPolicy` as first-class values; `Recoverable` / `Fatal` `ErrorKind`; naming helpers
  and smart-constructor module; GADT-indexed state machines for multi-state workflows;
  toolchain pin reaffirmation on GHC `9.14.1` / Cabal `3.16.1.0`; one-shot CLI output
  discipline with `--format` / `--color` / `--no-color` and stdout/stderr split; one-shot
  `Env` record and `ReaderT App` adoption; pinned style-tools sandbox under
  `.build/prodbox-style-tools/` plus custom nesting warnings and negative-space
  symbol rules refusing `forkIO`, `unsafePerformIO`, and module-level `IORef` in daemon paths;
  aggregate `prodbox test lint` dispatch with lint-first ordering of `prodbox test all`;
  `trackingGeneratedPaths` registry plus renderer determinism contract; standardized library
  audit of `prodbox.cabal`; `dhall freeze` discipline on the committed repo-root config path
  plus the `lint docs` ↔ `docs check`/`docs generate` naming-consolidation decision and the
  parser `--foreground` default plus self-daemonization-forbidden rule; and — added by Sprint
  0.3 — durable CLI documentation artifacts under `documents/cli/`, `share/man/`, and
  `share/completion/` registered in `trackingGeneratedPaths`; the `execParserPure`
  parser-test category in the `prodbox-unit` stanza; and the `renderError` error-rendering
  boundary discipline with hlint rules refusing `print`, `exitFailure`, and direct terminal
  formatting outside the dedicated output layer. Sprint 0.4 adds Sprint 1.27 (cabal-manifest
  `tested-with: ghc ==9.14.1` and `with-compiler: ghc-9.14.1` declarations, the literal
  `Cabal 3.16.1.0` reference, and the library-first / thin-`Main.hs` audit through
  `src/Prodbox/CheckCode.hs`) and threads the round-3 extensions through Sprint 1.6
  (`CommandSpec` / `OptionSpec` record-field bindings plus daemon-as-typed-`Command`
  dispatch), Sprint 1.8 (typed `Subprocess` record plus removal of the pre-doctrine
  `CommandSpec`, `runStreamingCommand`, and `captureCommand` compatibility names), Sprint 1.10
  (twelve minimum `fourmolu.yaml` settings bound), Sprint 1.11 (canonical
  property-test invariants `decode . encode == id`, `render is deterministic`,
  `parser roundtrips`), Sprint 1.12 (service-error newtype inventory `MinIOError`,
  `RedisError`, `PgError`), Sprint 1.14 (`AppError` record shape `errorKind`,
  `errorMsg`, `errorCause :: Maybe SomeException`), Sprint 1.15 (naming-helper
  signatures with DNS-1123 / 63-character constraints), and Sprint 1.21 (enumerated
  forbidden renderer inputs).
- Phase 2 — **Sprints 2.9–2.16**: Explicit daemon lifecycle
  (`load→prereq→acquire→ready→serve→drain→exit`) with worker loops wrapped in `try`/`catch`
  + bounded retry-with-backoff; `/healthz`, `/readyz`, `/metrics` endpoints with response
  shapes captured as golden tests; `BootConfig` / `LiveConfig` split with `SIGHUP` hot
  reload and atomic-swap discipline on `envLiveConfig`; structured JSON logging via `co-log`;
  test hooks in `Env`; `prodbox-daemon-lifecycle` test stanza asserting that single SIGTERM
  begins drain and second SIGTERM (or drain deadline) forces exit; daemon CLI plumbing
  (`--config`, `--log-level`, `--port`, `--foreground`) plus `PRODBOX_*` env-var precedence
  rule; formal at-least-once event-processing module
  (`src/Prodbox/Daemon/Events.hs`) with `StoredEvent` / `recordEvent` /
  `markEventProcessed` / `fetchUnprocessedEvents` and idempotent `EventHandler`; and — added
  by Sprint 0.3 — the default 30 s drain deadline plus explicit `bracketOnError` on
  external-side-effect resources (2.9); the `envMetrics :: MetricsRegistry` typed daemon
  `Env` field consumed by `/metrics` (2.10); the STM broadcast channel for `LiveConfig`
  subscribers plus the prescribed on-disk Dhall file shape (2.11); and the daemon log
  level refreshed from `LiveConfig` on every hot reload (2.12). Sprint 0.4 threads the
  round-3 extensions through Sprint 2.9 (enumerated structured-concurrency primitive set
  `withAsync` / `race` / `concurrently` / `replicateConcurrently`), Sprint 2.11 (forbidden
  reload triggers `fsnotify`, `inotify`, `mtime` polling; typed `schemaVersion : Natural`
  Dhall field with mismatch-as-parse-failure; eight-step reload procedure step-by-step),
  Sprint 2.12 (typed `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` helper
  plus `logStructured` / `logDebug` / `logInfo` / `logWarn` / `logError` wrappers),
  Sprint 2.13 (production-no-op / test-injected hook contract bound), and Sprint 2.14
  (health-endpoint response shapes captured as golden tests inside the lifecycle stanza).
- Phase 3 — **Sprints 3.8–3.12**: Smart constructors for paired chart resources; capability
  classes applied to Redis and Postgres chart call sites; reconciler discipline on
  `prodbox charts deploy` / `delete`; `--dry-run` on chart operations; `prodbox lint chart`
  Helm-chart structural-invariants linter; and marker-delimited route-inventory generation
  from `src/Prodbox/PublicEdge.hs` into chart artifacts via the `GeneratedSectionRule`
  registry. Sprint 0.4 extends Sprint 3.10 with the named forbidden reconciler flags
  (`--force`, `--reinstall`) and forbidden sister commands (`install`, `upgrade`,
  `repair`, `force-install`) on the chart surface.
- Phase 4 — **Sprints 4.5–4.8**: Rename the legacy lifecycle command to
  `prodbox rke2 reconcile`, retire the one-cycle `install` alias after its compatibility
  window, apply lifecycle Plan / Apply + `--dry-run`, and add the `prodbox-pulumi` test
  stanza. Sprint 0.4 extends Sprint 4.5 with the same forbidden-flag and sister-command
  discipline on the lifecycle reconciler, so `install`, `upgrade`, `repair`, and
  `force-install` are rejected at parse time. Sprint `4.8` makes successful
  `prodbox rke2 delete --yes` runs hermetic and summary-owned by `prodbox`, while preserving
  actionable upstream context on failure.
- Phase 4 — **Sprints 4.10–4.13** (added May 21, 2026 to bind the lifecycle reconciliation
  doctrine into code): Sprint `4.10` decouples long-lived Pulumi state onto a dedicated
  operator-account S3 bucket so the `aws-ses` stack survives `rke2 delete + rke2 reconcile`
  cycles. Sprint `4.11` introduces the composable `Precondition` algebra and the
  `prodbox rke2 delete --cascade` / `--allow-pulumi-residue` flag matrix (mutually exclusive
  at parse time) so orphaning per-run Pulumi-managed AWS resources is structurally
  impossible. Sprint `4.12` adds the K8s drain phase that deletes LoadBalancer Services, ALB
  Ingresses, and Delete-reclaim PVCs before per-run Pulumi destroys, so AWS-side controllers
  can unwind cleanly. Sprint `4.13` introduces `prodbox nuke`, the operator-only total-
  teardown command that refuses non-TTY contexts and requires the typed-confirmation
  literal `NUKE EVERYTHING`. Code frameworks for all four sprints landed May 21, 2026; the
  live operator validations (AwsSesStack admin-credential switch + live migration body,
  live cascade exercise against a running cluster, live `nuke` exercise) are tracked as
  remaining work in the respective sprint blocks.
- Phase 4 — **Sprints 4.14 + 4.15** (added May 21, 2026 from the live
  `prodbox rke2 delete --help` and `--cascade --yes` review):
  Sprint `4.14` enforces the operator vocabulary contract introduced
  in
  [cli_command_surface.md § 2A](../documents/engineering/cli_command_surface.md#2a-operator-vocabulary-contract)
  — `Sprint <number>` labels and other dev-plan tracking vocabulary
  must not appear in any operator-facing CLI surface
  (`prodbox <command> --help`, manpages under `share/man/`, shell
  completions under `share/completion/`, the generated
  `documents/cli/commands.md`, or stdout/stderr emitted by the
  binary at runtime). Implementation rewrites the sprint-tagged
  strings in `src/Prodbox/CLI/Spec.hs` and the cascade narration in
  `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade`, then adds a
  `Sprint [0-9]` regex scan to `prodbox check-code`. Sprint `4.15`
  closes the symptom surfaced when an operator runs
  `prodbox rke2 delete --cascade --yes` on a host without a cluster:
  the drain phase currently calls `kubectl delete services` against
  `localhost:8080` and fails noisily. Implementation adds a
  `DrainSkipped <reason>` constructor to the `DrainResult` ADT in
  `src/Prodbox/Lifecycle/K8sDrain.hs`, a quick
  `kubectl cluster-info --request-timeout=5s` reachability probe,
  and a cascade caller arm that treats `DrainSkipped` as
  success-with-reason — matching the
  [reconciler-with-predicates doctrine](../documents/engineering/lifecycle_reconciliation_doctrine.md#3-the-reconciler-with-predicates-pattern)
  rule that source-of-truth queries tolerate the case where the
  authoritative source is already gone.
- Phase 5 — **Sprint 5.5**: Add a Gateway API HTTP listener on port `80` that never routes
  plaintext backend traffic and only returns a permanent redirect to the canonical
  `https://test.resolvefintech.com/<service-path>` URL. Extend `prodbox host public-edge` and
  the external public-host validation surface to prove the redirect alongside the existing
  HTTPS-only application traffic contract. This follow-up is `Done` and was validated by the
  May 13, 2026 `./.build/prodbox test all` run.

The earlier alignment follow-up on native `gateway-partition` validation, peer trust-material
runtime closure, root-chart-only public chart commands, the Harbor-plus-storage-backend
bootstrap contract, and the later Phase `2` cleanup follow-up that removed the retained legacy
`NTP synchronized` `timedatectl` parser branch in `src/Prodbox/Host.hs` is complete in both
governed docs and code; those closures sit inside the Sprint 1.1–1.5, 2.1–2.8, 3.1–3.7,
4.1–4.4, 5.1–5.4, 6.1–6.3, and 7.1–7.N surfaces and are unchanged by the doctrine reopen.

The authoritative target still closes on:

- one Haskell-owned CLI, lifecycle, Pulumi, gateway-daemon, public-workload, chart, onboarding,
  AWS, and test surface
- one direct `Dhall -> Haskell types` config contract rooted at operator-authored
  `prodbox-config.dhall`
- one Harbor-first local lifecycle that reconciles MetalLB, Envoy Gateway, cert-manager, Harbor,
  MinIO, and the Percona PostgreSQL operator on the supported self-managed cluster path
- one supported public-edge doctrine where every externally reachable application or dashboard sits
  behind Envoy Gateway on `test.resolvefintech.com`, distinguished only by explicit path prefixes
  such as `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio`, protected by Keycloak-
  backed JWT auth or RBAC, covered by one Route 53 record plus one listener certificate, and
  fronted by a port `80` HTTP listener that only redirects to HTTPS
- one native-host-architecture lifecycle image-publication doctrine where `amd64` hosts build and
  publish only `amd64` images, `arm64` hosts build and publish only `arm64` images, and no
  supported path uses `docker buildx` or cross-arch emulation
- one explicit steady-state JWT boundary where Envoy validates Keycloak-issued tokens locally and
  does not require per-request Keycloak or Redis calls on the hot path
- one explicit Keycloak availability boundary where new logins, refresh flows, and later JWKS
  refresh depend on Keycloak, while the steady-state JWT hot path at Envoy does not require
  per-request Keycloak or Redis access
- one explicit distinction between the Envoy Gateway public edge and the separate Haskell
  distributed gateway daemon shipped through `prodbox gateway ...` and
  `prodbox charts deploy gateway`
- one explicit current transport boundary where public TLS terminates at Envoy and backend TLS or
  mTLS stays outside the supported chart-workload contract unless a later doctrine revision
  expands that path
- one Redis surface that currently backs WebSocket shared state and may later back an explicit
  external rate-limit service, but does not yet ship a standalone rate-limit-service workload or
  validation surface
- one cleanup ledger that preserves completed removal history and has no still-open
  doctrine-adoption residue

The implemented clean-room rerun proof remains the Phase `6` command contract expressed through
`prodbox test all`, `prodbox config show`, `prodbox config validate`, and
`prodbox host public-edge`. Separate repository review gates still verify that `example.com` and
zero-Python residue stay out of supported-path sources, but those checks are not a dedicated
`prodbox` command. The canonical automated validation contract otherwise remains the `prodbox`
command surface documented by this plan: `prodbox check-code`,
`prodbox test unit`, `prodbox test integration cli`, `prodbox test integration env`, and the
canonical test suite behind `prodbox test integration ...` (planned by
`src/Prodbox/TestPlan.hs`, dispatched by `src/Prodbox/TestValidation.hs`, orchestrated by
`src/Prodbox/TestRunner.hs`). Per
[development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
that canonical suite runs against substrates — today the home local substrate and the AWS
substrate (see [substrates.md](substrates.md)) — and substrate-specific provision and
teardown belong to the substrate-owning phase docs, not to suite content. Substrate parity is
tracked in [substrates.md](substrates.md) and in the Substrate Parity table below.

The rewrite remains on the canonical phase model required by
[development_plan_standards.md](development_plan_standards.md).

## Document Index

| Document | Purpose |
|----------|---------|
| [development_plan_standards.md](development_plan_standards.md) | Conventions for maintaining the development plan |
| [system-components.md](system-components.md) | Authoritative target component inventory for the Haskell rewrite |
| [substrates.md](substrates.md) | Authoritative inventory of substrates the canonical test suite runs against |
| [00-overview.md](00-overview.md) | Target architecture, current baseline, and hard constraints |
| [phase-0-planning-documentation.md](phase-0-planning-documentation.md) | Phase 0: Planning and documentation topology for the rewrite |
| [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) | Phase 1: Haskell runtime, CLI, config, and Pulumi foundations |
| [phase-2-gateway-dns.md](phase-2-gateway-dns.md) | Phase 2: Haskell gateway runtime and DNS ownership |
| [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) | Phase 3: Haskell chart platform and public workload delivery |
| [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) | Phase 4: Lifecycle hardening, Pulumi decoupling, and Python removal |
| [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) | Phase 5: Canonical test suite — substrate-agnostic named validations |
| [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) | Phase 6: Final clean-room rerun and zero-Python handoff |
| [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Phase 7: AWS substrate foundations — onboarding, IAM, quota, and AWS substrate parity with the canonical suite |
| [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Phase 8: Operator-invited email authentication via Keycloak + AWS SES |
| [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) | Comprehensive ledger of cleanup/removal history and ownership |

## Sprint Status

### Status Vocabulary

| Status | Meaning | Emoji |
|--------|---------|-------|
| **Done** | Deliverables implemented for the sprint-owned surface, validated, and aligned in docs | ✅ |
| **Active** | Work has started and remaining implementation or documentation work is explicitly listed | 🔄 |
| **Blocked** | Closure depends on an unmet prerequisite or prior sprint closure | ⏸️ |
| **Planned** | Ready to start once execution reaches the sprint in sequence | 📋 |

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Its deliverables are implemented in the worktree.
2. Its validation commands pass through the canonical `prodbox` surface.
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned blocker or remaining work survives.

## Phase Overview

| Phase | Name | Status | Document |
|-------|------|--------|----------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ Done (Sprints 0.1–0.7) | [phase-0-planning-documentation.md](phase-0-planning-documentation.md) |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ Done (Sprints 1.1–1.27) | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ Done (Sprints 2.1–2.16) | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Public Workload Delivery | ✅ Done (Sprints 3.1–3.12) | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ Done (Sprints 4.1–4.8); 🔄 Active Sprints 4.10–4.13 (code frameworks landed May 21, 2026: 4.10 Dhall types + Settings.hs decoder + `LongLivedPulumiBackend` module + `aws-ses-migrate-backend` CLI scaffold; 4.11 `Lifecycle/Preconditions` + `Lifecycle/TagSweep` + `rke2 delete --cascade` / `--allow-pulumi-residue` flags with mutual exclusion; 4.12 `Lifecycle/K8sDrain` module wired into cascade; 4.13 `prodbox nuke` CLI scaffold with TTY guard + typed-confirmation literal + dry-run plan renderer. Sprint 4.13's five-step nuke orchestration body landed May 21, 2026 (composes cascade arm → `aws-ses` destroy → operational IAM teardown → postflight tag sweep → long-lived state-bucket destroy in-process, prompting once for admin AWS credentials at the start); Sprint 4.10's `pulumi/aws-ses/Pulumi.yaml` long-lived S3 backend URL declaration landed the same day. AwsSesStack admin-credential switch + migrate-backend body + `aws teardown` predicate library reimplementation + every live operator validation remain pending.); ✅ Sprint 4.14 (operator vocabulary contract enforcement: `Sprint <digit>` leaks removed from CLI help / manpages / completions / generated CLI docs / test goldens; new `checkOperatorVocabulary` scan in `src/Prodbox/CheckCode.hs` refuses regressions; May 21, 2026); ✅ Sprint 4.15 (cascade tolerates absent cluster: new `DrainSkipped String` constructor on `DrainResult`; new `clusterReachable` probe; `runNativeDeleteCascade` treats `DrainSkipped` as success-with-reason and continues to per-run Pulumi destroys; verified live on a host without an rke2 cluster; May 21, 2026) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Canonical Test Suite | ✅ Done on owned surfaces (Sprints 5.1–5.5) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ Done on owned surfaces | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | AWS Substrate Foundations | ✅ Done on legacy surfaces (Sprints 7.1–7.4); 🔄 Active Sprint 7.5 (✅ 7.5.a–7.5.c.iv on their code-owned surfaces, May 17–19, 2026; ✅ 7.5.c.v.b in-cluster custom-image push, May 19, 2026; ✅ 7.5.c.v.c harness preflight residue policy `BypassAllResidueForHarnessRefresh`, May 20, 2026; ✅ 7.5.c.v.d operational IAM policy compaction + S3 grants on SES capture bucket, May 20, 2026; ✅ 7.5.c.v.e read-only SES grants for Sprint 8.4 prereqs, May 20, 2026; ✅ 7.5.c.v.f silent-exit closure on code-owned surface (substrate-aware `prodbox host public-edge --substrate {home-local,aws}` + stderr breadcrumbs on `runNativeValidation`), May 21, 2026; 🔄 Sprint 7.5.c.v live AWS-substrate canonical-suite re-run remains as the residual live operator step); ✅ Sprint 7.6 (orphan-safety refuse-path + auto-destroy postflight, May 19, 2026); ✅ Sprint 7.7 (generalized `aws teardown` + `PulumiResiduePolicy` ADT + admin-credential prompt UX, May 19, 2026) | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | 🔄 Active (✅ Sprint 8.1 code + doctrine + live SES provisioning + verification May 18, 2026; ✅ Sprint 8.2 Keycloak realm chart + live deploy proof on home substrate May 18, 2026; ✅ Sprint 8.3 CLI surface + live Keycloak admin API HTTP integration; ✅ Sprint 8.4 SES prerequisites; 🔄 Sprint 8.5 suite content + dispatch arm + live invite/capture/link-follow steps + SES SMTP IAM-to-SMTP-password derivation + chart-secrets persistence landed (credential-setup form POST + fresh OIDC login + claim assertions remain operator-driven sub-sprint, blocked on live Keycloak form-structure capture); 🔄 Sprint 8.6 doc parity landed (live cross-substrate proof pending 7.5.c + 8.5 OIDC follow-up closure). Sprints 8.1–8.4 ✅ Done; 8.5–8.6 carry the only remaining live OIDC closure work) | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |

**Status interpretation**: Phase `0` reopened through Sprints `0.2`–`0.7` to adopt
[the engineering doctrine docs](../documents/engineering/README.md) and to add the LLM/automation guardrails on
the interactive command surface; Phase `0` is now `Done` on that planning, documentation, and
non-TTY-guardrail surface. Phases `1`–`4` were reopened on the downstream doctrine-driven
implementation work and are now reclosed. Phase `5` is re-closed after Sprint `5.5` added and
proved the port `80`
HTTP-to-HTTPS redirect on the existing single-host public edge. The pre-reopen Haskell rewrite
baseline, clean-room rerun, public-edge proof, and AWS-administration surfaces remain validated
on the supported Haskell command surface; Phases `5`, `6`, and `7` remain `Done` on their owned
legacy scope per standards rule E. Phase `7` is **Active** on Sprint `7.5`, which the May 17,
2026 scoping review split into three sequentially-validatable sub-sprints (`7.5.a`, `7.5.b`,
`7.5.c`) to bring the AWS substrate to canonical-suite parity with the home substrate. Sprint
`7.5.b.iii` (substrate-independence doctrine refactor) was added between `7.5.b` and `7.5.c`
to make the no-fallback contract explicit across the governed doc set and is now `Done`.
Sprint `7.5.c`'s code follow-up landed May 18, 2026 — `substratePublicFqdn` /
`substrateHostedZoneId` are fail-fast on empty AWS-substrate config,
`resolveAwsEksSubzoneStackConfig`'s pre-provision gate requires only `subzone_name`,
`isAwsSubstrateConfigured` is removed, and the matching legacy-ledger row is moved to
`Completed`. The May 20 round of code-side closures (Sprints `7.5.c.v.c`, `7.5.c.v.d`,
`7.5.c.v.e`) unblocked the harness preflight against the long-lived `aws-ses` stack,
compacted the operational IAM policy under AWS's 2048-byte inline-user-policy cap, and added
the read-only SES grants the Sprint 8.4 prereqs need. The May 20 live re-run cleared every
prior gate and entered Phase 2/2 of the suite, but every named `--substrate aws` validation
body returned silently before producing output. Sprint `7.5.c.v.f` closed that diagnosis
on May 21, 2026 on its code-owned surface: `prodbox host public-edge --substrate
{home-local,aws}` threads `Substrate` end-to-end through `runHostPublicEdge`,
`queryRoute53RecordInZone`, `waitForPublicEdgeReady`, and the four substrate-aware
public-edge validation bodies, while `runNativeValidation` emits stderr breadcrumbs around
every body so silent exit is structurally impossible at the runner level. The live
AWS-substrate canonical-suite re-run (`prodbox test all --substrate aws`) closes Sprint
`7.5.c.v` and the parent Sprint `7.5.c`; the documented operator workflow lives in
[phase-7-aws-substrate-foundations.md → Sprint 7.5.c Operator Workflow](phase-7-aws-substrate-foundations.md).

Phase `8` was opened May 18, 2026 with the full code + doctrine layer of Sprints
`8.1`–`8.6` landed in a single session: `pulumi/aws-ses/` (Pulumi program for the
SES sending identity, receive subdomain MX, receive rule set, S3 capture bucket, and
SMTP IAM user); `src/Prodbox/Infra/AwsSesStack.hs` orchestration plus
`prodbox pulumi aws-ses-resources` / `aws-ses-destroy` CLI surface; the
`ses : { sender_domain, receive_subdomain, capture_bucket }` block in
`prodbox-config-types.dhall` and `prodbox-config.dhall`; Keycloak realm chart updates
(`verifyEmail: true`, `smtpServer`, new `keycloak-smtp` `Opaque` Secret) under
`charts/keycloak/`; the operator-facing `prodbox users invite|list|revoke` surface in
`src/Prodbox/CLI/Users.hs` and `src/Prodbox/UsersAdmin.hs`; three new
prerequisite nodes (`ses_sending_identity_verified`, `ses_receive_rule_set_active`,
`ses_receive_bucket_accessible`) wired through `src/Prodbox/Effect.hs`,
`src/Prodbox/Prerequisite.hs`, and `src/Prodbox/EffectInterpreter.hs` with AWS CLI
validators; the `ValidationKeycloakInvite` / `IntegrationKeycloakInvite` canonical-suite
variants planned by `src/Prodbox/TestPlan.hs` and dispatched through
`src/Prodbox/TestValidation.hs`; and the cross-substrate shared-SES doctrine in
[substrates.md](substrates.md) and
[documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md).
Validated with `prodbox check-code`, `prodbox lint docs`, `prodbox docs check`, and
`prodbox test unit` (312/312). The residual live operator workflows for Phase `8` are
parallel to Sprint `7.5.c`'s live workflow: `prodbox aws setup` →
`prodbox pulumi aws-ses-resources` (Sprint `8.1` live), the Sprint `8.5` Keycloak admin
API HTTP integration in `src/Prodbox/UsersAdmin.hs` plus the SES capture-bucket polling
helper in `src/Prodbox/TestValidation.hs::runKeycloakInviteValidation`, and the Sprint
`8.6` cross-substrate `keycloak-invite` parity flip in [substrates.md](substrates.md).

## Substrate Parity

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates,
with no fallback between them (see
[Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)).
A complete canonical-suite proof requires both the home local and AWS substrate rows below to
land independently against their own real infrastructure. The authoritative substrate
inventory is [substrates.md](substrates.md); this section is the live tracker for substrate
parity. The authoritative AWS resource inventory and per-resource lifecycle class (auto-managed
per-run stacks vs long-lived cross-substrate shared infrastructure) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Teardown | Suite parity | Phase ownership |
|-----------|-----------|----------|--------------|-----------------|
| Home local | `prodbox rke2 reconcile` + `prodbox charts deploy ...` | `prodbox rke2 delete --yes` | ✅ Full canonical suite, including real Let's Encrypt, OIDC, WebSocket, and public-edge proofs on `test.resolvefintech.com` | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| AWS | `prodbox pulumi eks-resources` + `prodbox pulumi aws-subzone-resources` + `prodbox pulumi test-resources` | `prodbox pulumi aws-subzone-destroy --yes` + `prodbox pulumi eks-destroy --yes` + `prodbox pulumi test-destroy --yes` | 🔄 Substrate-platform install (13 steps) lands on EKS; harness preflight and IAM policy compaction landed May 20, 2026; substrate-aware validation bodies + stderr-breadcrumb runner landed May 21, 2026 (Sprint `7.5.c.v.f`); live `prodbox test all --substrate aws` re-run rolls up into Sprint `7.5.c.v` | [phase-7-aws-substrate-foundations.md → Sprint 7.5](phase-7-aws-substrate-foundations.md) |

## Current Plan Status

The development plan remains authoritative. The repository worktree is fully closed against the
pre-reopen scope (Sprints 1.1–1.5, 2.1–2.8, 3.1–3.7, 4.1–4.4, 5.1–5.4, 6.1–6.3, 7.1–7.4), and
the doctrine-adoption reopen is now closed as well. Current worktree evidence puts Sprints
`0.7`, `1.6`–`1.27`, `2.9`–`2.16`, `3.8`–`3.12`, `4.5`–`4.8`, `4.14`, `4.15`, `5.5`,
`7.5.a`/`7.5.b.*`/`7.5.b.iii`/`7.5.c.i`–`7.5.c.iv`/`7.5.c.v.b`/`7.5.c.v.c`/`7.5.c.v.d`/
`7.5.c.v.e`/`7.5.c.v.f`, `7.6`, `7.7`, and `8.1`–`8.4` in `Done` state on their owned surfaces.
Sprints `4.10`–`4.13` have their full code bodies landed on their code-owned surfaces (May 21,
2026: Sprint 4.10's admin-credential switch + in-process migrate-backend body + Pulumi.yaml
backend URL; Sprint 4.11's full predicate inventory `noLivePerRunPulumiStacks`,
`noLiveLongLivedPulumiStacks`, `noLiveClusterTaggedAws`, `noUndrainedK8sAwsResources`,
`noLiveOperationalIamUser`, `noLeftoverDnsBootstrapRecords`; Sprint 4.13's
five-step nuke orchestration body + `destroyLongLivedPulumiStateBucket` helper); each was
exercised against the home substrate through `prodbox test all` runs that reached
`ready-for-external-proof` classification and ran every named canonical validation through to
the per-run Pulumi destroys. The live destructive `nuke` exercise and the live cascade exercise
against a running AWS-side cluster remain operator-driven follow-ups. A Sprint `7.5.c.v.d`
follow-up landed the same day to extend the operational IAM policy with the
`iam:CreatePolicy` / `CreateOpenIDConnectProvider` lifecycle actions the EKS Pulumi program
needs (run 3 / run 4 surfaced both gaps via live AWS AccessDenied); after the grants landed the
`aws-eks` validation provisioned EKS + LB controller IRSA + EBS CSI IRSA + OIDC provider and
destroyed cleanly. The remaining `Active` work outside Phase `4`
is: Sprint `7.5.c.v` (live AWS-substrate canonical-suite re-run, operator-driven against live
AWS) and Sprints `8.5`–`8.6` (live Keycloak credential-setup form-structure capture +
parser wire-in into `runKeycloakInviteValidation` + cross-substrate parity flip; the
form-parser scaffold lives in `src/Prodbox/Keycloak/CredentialSetupForm.hs` with synthetic
fixture). The following implemented baseline surfaces remain current on
the supported path:

- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding repo-root `prodbox-config.dhall` in-process through the native `dhall` library, without
  materializing `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/EnvSuite.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, repository-root config-path
  resolution, and the built-frontend env proof for the direct-Dhall settings surface.
- `src/Prodbox/CheckCode.hs` now enforces the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`: it fails on repository-owned workflow or git-hook
  surfaces before it runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary
  sync step, while excluding generated or retained runtime roots such as `.build/`,
  `dist-newstyle/`, `.prodbox-state/`, and `.data/` from the repo-owned policy scan.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- The public `config setup` and public `aws ...` surfaces use prompt-driven temporary admin AWS
  credentials (historically called "elevated credentials"), while stored
  `aws_admin_for_test_simulation.*` remains reserved for test-suite simulation of that prompt
  input, with the native IAM validation harness as the only supported runtime consumer.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, `prodbox test integration all`, and
  `prodbox test all` through one shared suite-level IAM harness that provisions temporary
  operational `aws.*` before prerequisite-driven AWS validation begins and clears those
  credentials again before the suite returns.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `rke2 reconcile`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The shared IAM harness deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, proves STS-federated operational credentials with a compact
  AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS and
  repeated Route 53 hosted-zone probes, materializes IAM-user operational `aws.*` only from
  `aws_admin_for_test_simulation.*` because cert-manager Route 53 DNS01 credentials do not
  support an STS session-token field, and clears `aws.*` from `prodbox-config.dhall` before
  returning even on later prerequisite failure.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  repository-root credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every repository-owned
  Haskell-build Dockerfile stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC
  `9.14.1`, and does not create symlinked Haskell tool shims.
- The authoritative local lifecycle target remains Haskell-owned and Harbor-first: Harbor plus
  Harbor's storage backend bootstrap from public registries, after which required public images
  and custom images are present in Harbor before later Helm deployments proceed.
- The Harbor mirror path retries transient Harbor publication failures on the same candidate and
  then falls through to alternate configured upstreams when publication still fails after manifest
  inspection, with `mirror.gcr.io` fallbacks now covering the Docker Hub-hosted Percona and Envoy
  images used by the supported lifecycle.
- The Haskell-owned lifecycle now retries transient upstream Helm fetch failures during
  `helm repo update` and `helm upgrade --install`, so clean-room restore does not fail terminally
  on intermittent upstream `5xx` or timeout errors.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on native-host-architecture image
  publication only: `amd64` hosts publish `amd64`, `arm64` hosts publish `arm64`, and no
  supported lifecycle path uses `docker buildx` or cross-arch emulation.
- The chart-platform end state is Haskell-owned and renders namespace-local
  Percona-operator-backed Patroni PostgreSQL HA through `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs`, with exactly three replicas, synchronous replication,
  deterministic retained PV bindings, retained secret state, and no embedded chart-local
  PostgreSQL subcharts.
- The public `prodbox charts ...` runtime now rejects internal `keycloak-postgres` and `redis`
  dependency releases directly and keeps those names reachable only through their owning root-
  chart orchestration.
- The public `prodbox pulumi ...` surface is limited to the AWS substrate stacks under
  `pulumi/aws-eks/` and `pulumi/aws-test/`. Non-secret validation inputs are synchronized through
  stack config, while AWS provider credentials stay only in `prodbox-config.dhall` and the
  Haskell-owned subprocess environment.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS substrate stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`; the HA-RKE2 validation destroys and recreates the retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails, repairing stale
  EC2 instances left by interrupted runs or operator network moves.
- The current gateway runtime surface is Haskell-owned and code-backed in `src/Prodbox/Gateway.hs`,
  `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, and
  `src/Prodbox/Gateway/Types.hs`: config generation, heartbeat recording, in-memory ownership
  projection, DNS-write gating, the bounded HTTP `/v1/state` observability payload, HMAC event
  signing, Orders-backed gateway-interval validation, peer-transport gossip with commit-log
  replication through `peerListenerLoop` and `peerDialerLoop`, runtime claim/yield emission under
  the `canWriteDns` predicate, bounded-clock-skew enforcement keyed off
  `daemonMaxClockSkewSeconds`, and monotonic Orders-version coordination across the mesh are all
  implemented there today.
- `prodbox test integration gateway-partition` now runs as a distinct native validation path,
  while the retained peer trust-material fields are validated and bound as authoritative runtime
  transport inputs.
- `src/Prodbox/Tla.hs` still owns `prodbox tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox pulumi ...` command
  family.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the clean-room Harbor, Envoy
  Gateway, cert-manager, and Percona reconcile path with no retained cluster-migration cleanup
  shims for Traefik or the pre-Percona operator surface.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi
  provider-key layouts on the supported path.
- The self-managed public edge now installs Envoy Gateway, renders Gateway API resources, and
  protects shared-host browser, API, WebSocket, and admin routes through Envoy auth policy.
- `src/Prodbox/CLI/Rke2.hs` now renders config-selected MetalLB L2 or BGP resources, lifts the
  Envoy Gateway controller and data-plane replica counts into settings, and builds or imports both
  the gateway image and the shared public-edge workload image during `rke2 reconcile`.
- The supported public-edge auth doctrine now makes the carrier and key-discovery boundary
  explicit: JWT-only API routes validate request-carried bearer tokens locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys, Envoy-managed browser auth returns
  through the edge redirect and cookie or session path, and direct-OIDC workloads keep their
  carrier or session state workload-owned.
- Keycloak availability now stays explicit in the plan: it is required for new logins, refresh
  flows, and later JWKS refresh, but the steady-state JWT request path does not synchronously call
  Keycloak or Redis while Envoy still has cached signing keys and the presented tokens remain
  valid.
- The current supported transport boundary now stays explicit in the plan: public TLS terminates at
  Envoy for the shipped `/vscode`, `/api`, and `/ws` routes on
  `test.resolvefintech.com`, while backend TLS or mTLS is outside the supported
  chart-workload contract unless a later doctrine revision expands that path.
- `src/Prodbox/PublicEdge.hs` now centralizes the shared-host route catalog and issuer derivation
  consumed by lifecycle, DNS, chart, host-diagnostic, and native validation surfaces, keeping
  `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio` aligned on one Haskell-owned
  public-edge contract.
- Root `README.md` plus the governed public-edge, gateway, chart-platform, registry, and testing
  doctrine docs now describe that same supported route catalog and command surface, and the
  earlier Phase `2`, `3`, and `4` implementation gaps are closed in the same code-backed paths.
- `charts/keycloak/`, `charts/api/`, `charts/redis/`, `charts/websocket/`, `charts/vscode/`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Workload.hs` now own the shared-host
  workload contract, including the internal `PRODBOX_WORKLOAD_MODE=api|websocket` runtime,
  JWT-only API delivery, Redis-backed shared-state continuity on the WebSocket route, workload-
  managed OIDC bootstrap, real `/ws` upgrade handling, and settings-backed workload scaling.
- The current WebSocket doctrine now states that one upgraded connection remains pinned to one
  selected backend pod until disconnect, reconnect-safe state must live outside the pod, and the
  implemented runtime now closes on readiness-based drain plus revocation-driven reconnect
  behavior on the real `/ws` path.
- Redis now stays explicit as shared application state for the current WebSocket surface and any
  later explicit external rate-limit service, but the current supported worktree still does not
  ship a standalone rate-limit-service workload or validation path.
- `src/Prodbox/Host.hs` and `src/Prodbox/TestValidation.hs` now classify and validate the
  current Keycloak identity, `vscode`, `api`, `websocket`, Harbor, and MinIO routes through named
  external validations on one shared hostname.
- `src/Prodbox/Host.hs` now recognizes only the supported
  `System clock synchronized` timedatectl field in `parseTimedatectlNtpDisposition`, so the
  Phase `2` host-info path closes on the Ubuntu 24.04 field format described by the current
  doctrine.
- `charts/gateway/` and `prodbox gateway start|status|config-gen` remain the separate Haskell
  distributed gateway daemon surface; they are not the Envoy Gateway public edge.
- The canonical validation surfaces are `prodbox check-code`, `prodbox test unit`,
  `prodbox test integration cli`, `prodbox test integration env`, the named Haskell-owned
  validation
  flows in `src/Prodbox/TestValidation.hs`, and the aggregate reruns
  `prodbox test integration all` plus `prodbox test all`.
- The aggregate rerun contract is owned by the shared suite plan behind
  `prodbox test integration all` and `prodbox test all`, including AWS IAM,
  Route 53, public-edge, EKS, HA-RKE2, destructive lifecycle, and post-test restore.
- The final Phase `6` destructive rerun and handoff validation are closed on that aggregate rerun
  contract and the supported postflight restore path.
- The legacy ledger preserves completed cleanup history, and its pending-removal section is empty
  after the doctrine-adoption reopen closure.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture and the Envoy
   Gateway target rather than the retired Python architecture or a Traefik end state.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   Pulumi orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from operator-authored
   repository-root `prodbox-config.dhall`, with `prodbox-config-types.dhall` aligned to the
   decoder and no generated `prodbox-config.json` artifact or supported `prodbox config compile`
   path.
4. Public `prodbox config setup` and public `prodbox aws ...` paths can bootstrap all required AWS
   credentials from scratch using temporary admin credentials entered interactively by the
   operator.
5. `aws_admin_for_test_simulation.*` may be stored in `prodbox-config.dhall` only as the
   test-suite simulation of the ephemeral temporary-admin credential prompt. The native IAM
   validation harness is the only supported runtime consumer of that section, and no supported
   non-test command or runtime helper may read or use it.
6. `prodbox test integration aws-iam`, `prodbox test integration all`, and `prodbox test all`
   share one joint idempotent IAM validation harness that deletes any pre-existing dedicated
   `prodbox` IAM user and all of that user's access keys before provisioning, uses any
   pre-existing `aws.*` credentials only to discover and delete the IAM user associated with those
   credentials, proves STS-federated operational credentials with a compact AWS-validation
   session policy, waits for the dedicated IAM-user credentials to pass STS and repeated Route 53
   hosted-zone probes, materializes IAM-user operational `aws.*` only from
   `aws_admin_for_test_simulation.*` to simulate the interactive public CLI workflow because
   cert-manager Route 53 DNS01 credentials do not support an STS session-token field, and clears
   operational `aws.*` from `prodbox-config.dhall` before returning so no test-created dedicated
   IAM user or key survives.
7. The operator-facing binary lives at `.build/prodbox`, produced by the canonical
   `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
8. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
9. Every repository-owned Haskell-build Dockerfile is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims; no
   supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
10. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
    upgraded for GHC `9.14.1`, including any required cabal-bound changes and full canonical
    validation reruns on that toolchain.
11. `prodbox check-code` enforces the governed doctrine-alignment contract described by
    `documents/engineering/code_quality.md`, not only formatter, linter, build, and binary-sync
    checks.
12. The Haskell distributed gateway runtime, `gateway status` client path, and daemon config
    validation close on the implemented bounded HTTP `/v1/state` observability payload, the
    Orders-backed gateway-interval relationships enforced by `src/Prodbox/Gateway/Types.hs`, and the current
    correspondence notes in `documents/engineering/tla_modelling_assumptions.md`.
13. The self-managed public edge uses MetalLB, Envoy Gateway, Kubernetes Gateway API, and
    cert-manager rather than Traefik plus `Ingress`.
14. Every externally reachable application or operational dashboard routes through Envoy on the
    single canonical hostname `test.resolvefintech.com`, using explicit path prefixes such as
    `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths.
15. The supported public-edge doctrine uses exactly one public DNS entry, one listener
    certificate, and no dedicated identity, browser, API, or WebSocket hostnames. Wildcard
    public DNS is unsupported.
16. `prodbox host public-edge`, `prodbox test integration charts-vscode`,
    `prodbox test integration charts-api`, `prodbox test integration charts-websocket`, and the
    named admin-route validations close on Gateway, `HTTPRoute`, auth policy, certificate, and
    one Route 53 record rather than `IngressClass`, `Ingress`, or per-FQDN state.
17. Supported config, onboarding, lifecycle, and validation surfaces remove `example.com`
    entirely and do not accept or emit placeholder public domains.
18. MetalLB supports both the L2 implementation path and a config-selected BGP implementation path
    on the supported self-managed cluster surface.
19. Envoy validates Keycloak-issued JWTs locally and applies route-level RBAC for application and
    admin routes. Issuer, audience, path-claim requirements, bearer-token carriers, browser
    return paths, and JWKS discovery or refresh ownership remain explicit.
20. Redis appears only as repo-owned app-level shared state for supported realtime or rate-limit
    workloads; it is never part of Envoy JWT validation, and the current supported worktree does
    not yet ship a standalone external rate-limit-service surface.
21. Supported WebSocket workloads authenticate at connection setup on the shared-host `/ws`
    route, keep reconnect-safe state outside the pod, keep each live upgraded connection pinned
    to one backend pod until disconnect, define token-expiry and authorization-change behavior
    explicitly, leave per-message authorization to the workload when messages need finer-grained
    permissions than the edge can enforce, scale horizontally behind Envoy, use readiness-based
    drain before pod exit, and add named validations for reconnect, connection-pinning,
    token-expiry handling, authorization-change assumptions, readiness-based drain,
    per-message authorization ownership, and shared-state assumptions.
22. Keycloak-backed public workloads stay proxy-aware behind Envoy on the shared hostname rather
    than on a dedicated identity host. Keycloak availability gates login, refresh, and later
    JWKS refresh, while cached signing keys and unexpired tokens keep the steady-state JWT hot
    path local to Envoy.
23. Public TLS terminates at Envoy on the supported path, and one certificate covers
    `test.resolvefintech.com`. Backend TLS or mTLS is not part of the current supported workload
    contract unless a later doctrine revision makes that backend transport explicit.
24. Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
    storage backend during bootstrap.
25. Every later supported Helm deployment obtains its images from Harbor.
26. `prodbox` idempotently ensures required public images and all custom images are present in
    Harbor after Harbor bootstrap and before those later deployments.
27. Supported custom-image builds and Harbor publication use only the native architecture of the
    machine running `prodbox`: `amd64` hosts build and publish `amd64` images, and `arm64` hosts
    build and publish `arm64` images.
28. Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
    cross-arch emulation, and mixed-arch cluster closure are not part of the supported lifecycle
    or chart-delivery path.
29. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
    cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
    synchronous replication, and no embedded chart-local PostgreSQL subchart.
30. Pulumi remains part of the supported architecture for true IaC and AWS substrate resources.
    The public `prodbox pulumi ...` surface stays limited to those stacks, while local-cluster
    lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
    `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
31. No supported Pulumi program depends on Python.
32. The strongest clean-room rerun passes from full local delete through final AWS teardown using
    the Haskell stack.
33. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
    cleanup.
34. The repository has no supported-path Python implementation or Python toolchain ownership
    artifacts left.
35. The Haskell gateway daemon materializes peer transport from the certificate, key, CA, and
    socket fields already retained in `DaemonConfig` and `Orders`: every node updates
    `stateLastHeartbeatTimes` from inbound peer events rather than from the local heartbeat loop
    only, the append-only commit log replicates between nodes as the canonical heartbeat-and-event
    transport, and `/v1/state` exposes per-peer transport health for operator inspection.
36. The gateway daemon emits signed `Claim` and `Yield` events on owner transitions and gates
    Route 53 writes on the runtime equivalent of the modelled `CanWriteDns` predicate, so
    `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the runtime event log rather than only
    on the model, and a stale owner cannot reclaim DNS write authority without first observing its
    own yield being superseded by a fresh claim.
37. The supported-host gate fails fast when the host's NTP synchronization state is unhealthy, the
    gateway daemon records the maximum observed inter-node clock skew on `/v1/state` and refuses
    inbound heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
    correspondence docs name that bound, the operator response, and how the model's bounded-delay
    assumption maps to a runtime-enforced skew limit.
38. Orders documents carry a monotonic version field, daemons reject inbound peer events from a
    peer presenting an older Orders version, a new Orders version propagates through commit-log
    gossip and is adopted by every live daemon before the next election tick, and a daemon
    rebooting against a stale Orders version refuses to claim ownership until its Orders view
    catches up.
