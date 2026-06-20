# Phase 1: Haskell Runtime, CLI, Config, and Pulumi Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md), [the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md)
**Generated sections**: none

> **Purpose**: Capture the Haskell runtime, CLI, configuration, build, and Pulumi foundations that
> make later gateway, chart, and public-host phases meaningful and testable, and own the
> CLI-doctrine adoption sprints that align those foundations with
> [the engineering doctrine docs](../documents/engineering/README.md).

## Phase Status

🔄 **Reopened 2026-06-16** (Tier 0 binary-context config surface) — Phase `1` is reopened to expand
its own config-SSoT surface with two 📋 Planned sprints that fold the non-secret config tier into a
single binary-owned `prodbox.dhall` shaped to `hostbootstrap`'s binary-context contract. Sprint
`1.39` folds `.data/prodbox/unencrypted-basics.json` and the non-secret sections of the seed/propose
`prodbox-config.dhall` into one binary-owned `prodbox.dhall` (`{parameters, context, witness}`, never
secrets), with a derived dependency-free `prodbox-basics.json` retained as the sealed-Vault bootstrap
floor; Sprint `1.40` ships the in-cluster half — a container-default `prodbox.dhall` overwritten by
the cluster daemon from a ConfigMap (the context-init pattern). Both are forward-only and build on the
closed Sprint `1.38` Tier 2 / SSoT-inversion surface; they adopt
[config_doctrine.md §0 (Three-Tier Config Model)](../documents/engineering/config_doctrine.md#0-three-tier-config-model)
and leave Tiers 1–2 unchanged. The `1.1`–`1.38` sprints remain `Done` on their owned surfaces (see
[README.md](README.md) Closure Status and rule A).

✅ **Reclosed 2026-06-16** (Vault-root + cluster federation foundations) — the Phase `1` Vault model is
finalized to the Vault-root end state: Vault is the sole secrets/KMS/PKI root, the master-seed
derivation model is retired (not extended), and `SecretRef` has no `FileSecret` arm. Sprint `1.38`
(Config SSoT Inversion and Root-Token-Gated Config Authority — the in-force config is the
Vault-Transit-enveloped MinIO object, filesystem `prodbox-config.dhall` is a seed/propose input
only, and root-cluster config writes require the root Vault token) joins the reframed Sprints
`1.35`–`1.37` (the `SecretRef` union carries **no** `FileSecret` arm; the `prodbox vault` group covers root init/unseal plus root lifecycle recovery; the
Pulumi sealed-Vault gate is mandatory before any `aws stack` op) — done on their Phase-owned surfaces
with the landed increments recorded below (see [README.md](README.md) Closure Status 2026-06-14,
rule A,
[vault_doctrine.md](../documents/engineering/vault_doctrine.md), and
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md)). The
landed parts of Sprints `1.36`/`1.37`/`1.38` — the encrypted unlock bundle, the native Vault HTTP
client, the full `prodbox vault` command group, the sealed-Vault gate decision
(`Prodbox.Vault.Gate`), the Pulumi apply-path gate wiring (`runPulumiCommandWithGate`), and the
production Vault-Transit `DekCipher` (`Prodbox.Vault.TransitCipher`), plus the unencrypted-basics
path, in-force payload decoder, MinIO envelope get/put edges, and injected in-force fetch/store
seams — have been validated through the local unit and CLI integration gates. Sprint `1.35`
closed on the `SecretRef` ADT / Dhall decoder / production validator / Vault resolver seam; the
later runtime migrations of AWS provider credentials and ACME EAB material remain owned by Sprints
`7.14` and `7.15`, respectively. Sprint `1.36`
additionally closed on 2026-06-16 with a native CLI Vault lifecycle integration proof, and Sprint
`1.37` closed on 2026-06-16 with a native CLI sealed-Vault refusal proof for `prodbox aws stack eks
reconcile`. Latest Phase `1` closure validation: `./.build/prodbox test unit` 910/910,
`./.build/prodbox test integration cli` 36/36, `./.build/prodbox dev docs check`,
`./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and `./.build/prodbox dev
check`. Sprint `1.38` subsequently closed the global `validateAndLoadSettings` loader switch:
once unencrypted basics exist, host settings loads read basics locally, recover the ready Vault root
token, read MinIO root credentials from Vault, and fetch/decrypt/decode the in-force config through
the Vault-Transit envelope instead of treating repo-root Dhall as the live SSoT. This finalization supersedes the 2026-06-11 "Vault
extends — it does not replace" framing for the derivation model specifically: Vault KV is now the
sole secret store and the HMAC-derivation model is retired.

✅ **Reclosed 2026-06-09** — Phase 1 was reopened for Sprints `1.29`–`1.32` by the 2026-06-09
design-intention review (see [README.md](README.md) Closure Status and rule A); all four have now
landed on their code-owned surfaces. Sprint `1.29` ✅ added a positional-args field to `CommandSpec`
and generated the [cli_command_surface.md](../documents/engineering/cli_command_surface.md) §2/§3
operator matrix from `commandRegistry` (the daemon/workload one-knob parser reduction was deferred
to Sprints `2.24`/`3.15`, where the override flags are actually removed). Sprint `1.30` ✅ made
`serviceErrorRetryable` real (a classifiable `ServiceError` sum classified at the single subprocess
boundary), split the retrier from the readiness-poller, introduced one PATH/HOME-preserving
`awsCliSubprocessEnvironment` and fixed the `Dns.hs` bare-`aws` PATH drop, deleted the dead `Retry`
exports, and converged the code to the D2 capability/error doctrine (rewritten in Sprint `0.9`).
Sprint `1.31` ✅ enforced prerequisite-DAG acyclicity at construction, collapsed
`settings_loaded`/`settings_object`, and added the interpreter satisfied-node memo. Sprint `1.32` ✅
retired the un-adopted `src/Prodbox/StateMachine.hs` plus its lone typecheck test and confirmed the
D1 GADT-doctrine softening (Sprint `0.9`). Validation at reclosure: `check-code` 0, `test unit` 756,
`lint docs` 0, `docs check` 0, `integration cli` 35/35. All earlier Phase 1 sprints (`1.1`–`1.28`)
remain `Done` on their owned surfaces.

✅ **Done (Sprints `1.1`–`1.28`)** — Sprints `1.1`–`1.5` remain `Done` on the Haskell-only rewrite baseline. The phase
is reopened by Sprint 0.2 (see
[phase-0-planning-documentation.md](phase-0-planning-documentation.md)) to schedule Sprints
`1.6`–`1.23`, which adopt the CLI doctrine across the CLI surface, runtime, configuration, test
harness, and lint stack and close the residual doctrine cleanup items (parser
`--foreground` default plus self-daemonization-forbidden rule, and the cross-language types
generation deferral). Sprint 0.3 extends the reopen to **Sprints `1.24`–`1.26`**, adding the
doctrine items surfaced by the May 2026 audit: durable CLI documentation artifacts, the
`execParserPure` parser-test category, and the `renderError` error-boundary discipline. Sprint
0.3 also extends the deliverable lists of Sprints 1.6 and 1.10 to require per-command
`CommandSpec` `Example` entries and the `cabal format` temp-file round-trip byte-equality
compare, respectively. Sprint 0.4 adds Sprint `1.27` and threads the round-3 doctrine bindings
through the existing Sprint `1` reopen set: `CommandSpec` / `OptionSpec` field names,
daemon-as-typed-`Command` dispatch, forbidden subprocess primitive names, the minimum
`fourmolu.yaml` settings, canonical property-test invariants, service-error newtype inventory,
`AppError` record shape, naming-helper signatures, and forbidden renderer inputs. The reopened
Phase `1` doctrine surface is now closed: capability classes cover MinIO, Redis, and PostgreSQL
service calls; retry and error-kind classification use the shared policy and `AppError` axes; the
state-machine, output, and one-shot `App` foundations are code-backed and test-covered; and the
standardized library audit is documented against the retained dependency set. Sprints `1.6`–`1.27`
are implemented in code, doc-aligned, and validated locally.

Phase `1` remains `Done` and is not reopened by the managed-resource-registry doctrine
([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md),
scheduled in Phase `4` Sprints `4.20`–`4.22`). That registry is a Phase `4` lifecycle
abstraction **built on** these Phase `1` foundations — the `Plan` / `Apply` discipline
(Sprint `1.7`), the declare-and-interpret Effect DAG (`src/Prodbox/EffectDAG.hs`), and the
capability classes + `AsServiceError` (Sprints `1.12`/`1.13`) — not a change to them.

## Phase Summary

**Independent Validation** (per
[development_plan_standards.md](development_plan_standards.md) Standards N/O): this phase is
validated entirely on its own owned surface — the host `prodbox` binary, the Haskell runtime,
the CLI/`CommandSpec` registry, the Dhall config and `SecretRef`/Vault contracts, and the Pulumi
program shape — through `prodbox dev check`, `prodbox test unit`, and
`prodbox test integration cli`/`env`, with no dependency on any later phase. Where a Phase `1`
contract touches infrastructure owned by a later phase (a deployed cluster, an unsealed live
Vault, live AWS spend, a live MinIO object store), it is exercised against the home/local
substrate, a fake, or a loopback Vault-compatible/Pulumi-record stub (e.g. the Sprint `1.36`
native CLI Vault lifecycle proof and the Sprint `1.37` sealed-Vault refusal proof both run
against loopback stubs). Forward build order is preserved — later phases compose these
deliverables — but build order is not a validation gate, and an incomplete later phase never
blocks, gates, or reopens Phase `1`; reopening this phase is only ever to expand its own owned
surface. Any proof that genuinely requires live infrastructure is a non-blocking
`Live-proof: pending` note on the owning later-phase sprint, never a Phase `1` gate.

This phase establishes the Haskell `prodbox` binary, the canonical Cabal build topology, the
repository-root Dhall config loader, the Haskell command runtime and test harness, and the Pulumi
foundations for true IaC plus AWS-substrate provisioning. It also owns the canonical frontend
image placement under `docker/`, the direct-Dhall config contract, the canonical-suite harness,
and the aligned
root guidance or engineering docs listed by its sprints. Later retirement of local-cluster
Pulumi ownership is Phase `4` work, not a change to the foundations closed here. Sprints `1.1`,
`1.2`, `1.3`, `1.4`, and `1.5` remain closed on the Haskell-only rewrite baseline. The phase
closes on the single-host public-edge config doctrine: one canonical public hostname,
`test.resolvefintech.com`, settings-backed MetalLB L2 or BGP rendering, explicit public-edge
scaling inputs, and Route 53 hosted-zone alignment enforced during supported config authoring. The
implemented frontend container doctrine uses
`ubuntu:24.04` with in-image `ghcup`, pinned GHC `9.12.4`, no symlinked Haskell tool shims, and
explicit repo package-bound updates.

Sprints `1.6` through `1.23` adopt the CLI doctrine from
[the engineering doctrine docs](../documents/engineering/README.md). They split the CLI parser into a
`CommandSpec`-driven source of truth, introduce the `Plan` / `apply` discipline with
`--dry-run`, formalize the `Subprocess` ADT and its interpreter boundary, add a remedy-hint
contract to the prerequisite registry, align the lint stack on a pinned `fourmolu.yaml` plus
`GeneratedSectionRule`, `forbiddenPathRegistry`, and `.hlint.yaml` negative-space symbol rules,
migrate the test stanzas from `hspec` to `tasty`, introduce capability classes and first-class
retry policies, encode the `Recoverable | Fatal` error axis, centralize naming helpers and
smart-constructor patterns, re-encode multi-state workflows as GADT-indexed state machines,
reaffirm the GHC `9.12.4` / Cabal `3.16.1.0` toolchain pin, and schedule the residual doctrine
cleanup in Sprint `1.23` (parser `--foreground` default plus self-daemonization-forbidden
rule, and the explicit cross-language-types generation deferral). Sprints `1.24` through `1.26` schedule the residual doctrine gaps surfaced
by the May 2026 doctrine-vs-plan audit: Sprint `1.24` schedules the durable CLI documentation
artifacts (Markdown command reference, manpages, shell completion scripts) derived from the
`CommandSpec` registry; Sprint `1.25` schedules the `execParserPure` parser-test category;
Sprint `1.26` schedules the `renderError` error-boundary discipline plus hlint rules refusing
`print`, `exitFailure`, and direct terminal formatting in non-boundary code. Sprint `1.26` is
now closed on the output-boundary enforcement and direct-terminal cleanup, and Sprint `1.27` is
closed on the cabal-manifest toolchain declarations plus library-first entrypoint gate.

## Current Baseline In Worktree

- The Haskell `prodbox` binary is the sole CLI owner. All Python source, Python packaging, and
  Python bridge modules have been removed from the repository.
- The frontend request ADT and entrypoint now close on native Haskell dispatch only:
  `src/Prodbox/CLI/Command.hs` exposes `RunNative`, and `app/prodbox/Main.hs` no longer carries a
  retained Python delegation branch.
- The supported Haskell config surface is `setup|show|validate`; `config compile` is removed. The
  rest of the supported command matrix remains Haskell-owned:
  `aws policy|setup|teardown|check-quotas|request-quotas`,
  `host ensure-tools|check-ports|info|firewall|public-edge`, `rke2`, `pulumi`, `dns check`,
  `gateway start|status|config-gen`, `workload start`, `charts`, `k8s health|wait|logs`,
  `check-code`, `test`, and `tla-check`.
- The tracked schema artifact is `prodbox-config-types.dhall`; the operator-authored repo-root
  config is `prodbox-config.dhall`, written by `prodbox config setup` and ignored from version
  control. `src/Prodbox/Settings.hs` and `src/Prodbox/Repo.hs` own decoding, display,
  repository-root discovery, and canonical config-path resolution without materializing
  `prodbox-config.json`.
- The host build contract copies the operator-facing binary to `.build/prodbox` after the
  canonical `cabal build --builddir=.build exe:prodbox` invocation and preserves the shared
  `.build/support` linker shim for supported local runs.
- `src/Prodbox/CheckCode.hs` now runs the repository-owned workflow and git-hook policy scan,
  Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary sync step, closing on the
  governed doctrine-alignment contract described by `documents/engineering/code_quality.md`. The
  repo-owned policy scan excludes generated or retained runtime roots such as `.build/`,
  `dist-newstyle/`, and `.data/`, so retained PV content does not become a
  false-positive doctrine surface.
- `src/Prodbox/CLI/Docs.hs` and `src/Prodbox/CheckCode.hs` now derive the durable CLI
  documentation artifacts from the command registry: the marker-delimited Markdown command
  reference in `documents/cli/commands.md`, the generated manpages under `share/man/man1/`,
  the generated shell completion scripts under `share/completion/`, and the tracked generated
  path enforcement behind `prodbox docs check|generate` and `prodbox lint files`.
- The canonical frontend container build now lives at `docker/prodbox.Dockerfile`.
- `docker/prodbox.Dockerfile` now preserves the `/opt/build` artifact contract through in-image
  `ghcup` with pinned GHC `9.12.4` and Cabal `3.16.1.0`; no mounted `haskell:9.6.7-slim`
  BuildKit toolchain context or symlinked Haskell tool shims remain on the supported path.
- `cabal.project` now carries the repo-level `with-compiler: ghc-9.12.4` pin and the temporary
  `allow-newer: *:base, *:template-haskell` allowance required by the current package set, while
  `prodbox.cabal` carries the package-bound updates required by that toolchain.
- `test/integration/EnvSuite.hs` proves built-frontend config masking and validation directly
  against repository-root Dhall config without recreating `prodbox-config.json`.
- Named external-proof payloads behind `prodbox test integration ...` run executable native
  Haskell validation flows through `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/EffectInterpreter.hs`, and the AWS-backed
  runtime modules now strip ambient AWS auth and profile variables before projecting
  repository-root credentials into supported subprocesses.
- The current repository ships YAML Pulumi programs under `pulumi/aws-eks/Main.yaml` and
  `pulumi/aws-test/Main.yaml`. These Pulumi stacks compose the AWS substrate (see
  [substrates.md](substrates.md)) and match the target Pulumi boundary.
- The self-managed local edge now installs MetalLB, Envoy Gateway, cert-manager, and the Percona
  PostgreSQL operator.
- The supported config surface uses one canonical public hostname,
  `test.resolvefintech.com`, and no supported path emits dedicated identity, browser, API, or
  WebSocket FQDN fields.
- The foundational edge surface now supports config-selected L2 or BGP MetalLB rendering plus
  settings-backed Envoy Gateway controller, Envoy data-plane, API, and WebSocket replica counts.
- `prodbox config setup` now validates that the canonical hostname belongs to the selected
  Route 53 hosted zone before it writes repository config, and the supported schema or fixtures
  no longer carry placeholder-domain residue.
- The canonical closure gates for this phase are the host artifact contract at `.build/prodbox`,
  `prodbox check-code`, and the built-frontend `cli` plus `env` integration suites.

## Sprint 1.1: Haskell Binary, Build Topology, and Command Surface ✅

**Status**: Done
**Implementation**: `app/prodbox/Main.hs`, `src/Prodbox/CLI/`, `src/Prodbox/Native.hs`, `prodbox.cabal`, `cabal.project`, `docker/prodbox.Dockerfile`, `docker/`, `test/unit/Main.hs`, `test/integration/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/local_registry_pipeline.md`

### Objective

Define the supported Haskell `prodbox` binary, host build artifact contract, and container-build
topology on the implemented rewrite path.

### Deliverables

- `app/prodbox/Main.hs` exists as the Haskell CLI entrypoint.
- The frontend request ADT and entrypoint dispatch directly to native Haskell commands with no
  retained delegation shim.
- The canonical host build invocation routes host build artifacts to `.build/` and copies the
  binary to `.build/prodbox` as the operator-facing build artifact behind the `prodbox`
  command surface.
- The only supported home for repository-owned Dockerfiles is `docker/`.
- The custom Haskell frontend image is single-stage from `ubuntu:24.04`, still emits artifacts
  under `/opt/build`, installs `ghcup` in-image, pins GHC `9.12.4`, and does not create
  symlinked Haskell tool shims.
- `prodbox.cabal` and `cabal.project` are explicitly upgraded for the pinned GHC `9.12.4`
  toolchain, including any required cabal-bound changes.
- The public command surface remains `prodbox` and preserves the full supported command matrix from
  [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md).

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. Host build proof: the canonical `cabal build --builddir=.build exe:prodbox` invocation plus
   the `.build/prodbox` copy step yields the runnable operator-facing binary artifact
6. Container build proof: the canonical frontend Dockerfile under `docker/` emits artifacts under
   `/opt/build` through in-image `ghcup`-managed GHC `9.12.4` with no symlinked Haskell tool
   shims
7. Repository path proof: no supported root-level `Dockerfile` remains
8. Aggregate reruns: `prodbox test integration all` and `prodbox test all`

### Current Validation State

- `src/Prodbox/CLI/Command.hs` and `app/prodbox/Main.hs` now close the frontend on `RunNative`
  only while preserving the repo-rootless `gateway start|status` contract through
  `canRunWithoutRepoRoot`.
- The host build contract is implemented through `cabal build --builddir=.build exe:prodbox` plus
  the `.build/prodbox` copy step in `src/Prodbox/BuildSupport.hs`.
- `docker/prodbox.Dockerfile` is the canonical frontend image definition, lives under `docker/`,
  is single-stage `ubuntu:24.04`, preserves `/opt/build`, installs `ghcup` in-image, pins GHC
  `9.12.4`, and does not create symlinked Haskell tool shims.
- `prodbox.cabal` and `cabal.project` now implement the explicit repo upgrade required by the
  revised doctrine.
- `test/unit/Main.hs` and `test/integration/CliSuite.hs` now assert the `docker/prodbox.Dockerfile`
  location and the updated container-build doctrine.
- Root guidance docs and the governed docs listed in `Docs to update` are aligned in this change
  with the canonical Dockerfile location and the implemented `ghcup` plus `ghc-9.12.4` doctrine.

### Remaining Work

None.

## Sprint 1.2: Dhall Settings, Command ADTs, and Haskell Test Harness ✅

**Status**: Done (May 24, 2026 alignment note: the host-side `Dhall.inputFile auto`
decoder in `src/Prodbox/Settings.hs` is the model for the in-cluster gateway daemon's
new `src/Prodbox/Gateway/Settings.hs` scheduled in Sprint 2.20. No host-side regression
or revision is required by the pure-Dhall config doctrine — Sprint 1.2's deliverables
already match the new SSoT at
[config_doctrine.md §9](../documents/engineering/config_doctrine.md#9-host-cli).)
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Native.hs`, `src/Prodbox/Repo.hs`, `test/unit/`, `test/integration/Main.hs`, `test/integration/CliSuite.hs`, `test/integration/EnvSuite.hs`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/effect_interpreter.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/haskell_code_guide.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/prerequisite_dag_system.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/streaming_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the settings, interpreter, subprocess, and test contracts on Haskell-owned modules.

### Deliverables

- `prodbox-config.dhall` is decoded into typed Haskell settings values in-process through the
  native `dhall` library (`Dhall.inputFile`).
- The shared Dhall schema in `prodbox-config-types.dhall` remains aligned with the Haskell
  decoder.
- No supported command or validation path materializes `prodbox-config.json`.
- The supported `prodbox config` surface is `setup|show|validate`; `config compile` is removed.
- The current command, effect, and result contracts are represented as Haskell ADTs.
- The Haskell-owned `prodbox host ensure-tools|check-ports|info|firewall`, `prodbox k8s
  health|wait|logs`, `prodbox test`, and `prodbox check-code` command frameworks are implemented
  on a Haskell-owned entry surface.
- `prodbox check-code` fails on governed doctrine-alignment violations described by
  `documents/engineering/code_quality.md`, not only on formatter, linter, build, or binary-sync
  failures.
- The named validation payloads behind `prodbox test integration ...` are executable native
  Haskell validation flows owned by `src/Prodbox/TestValidation.hs`.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. Repository artifact proof: after `prodbox config show` and `prodbox config validate`, no
   supported-path `prodbox-config.json` exists or is recreated

### Current Validation State

- `src/Prodbox/Settings.hs` and `src/Prodbox/Repo.hs` decode `prodbox-config.dhall`, locate the
  canonical repository-root config paths, validate the required config contract, and render masked
  `prodbox config show` output without materializing `prodbox-config.json`.
- Missing repo-root config now fails fast with explicit `prodbox config setup` guidance instead
  of surfacing a raw file-open exception from the Dhall loader.
- `src/Prodbox/BuildSupport.hs` owns the shared `.build/support` linker shim and the
  operator-facing binary sync to `.build/prodbox`.
- `src/Prodbox/CheckCode.hs` owns `prodbox check-code` and now runs the repository-owned workflow
  and git-hook policy scan, Fourmolu, HLint, warning-clean
  `cabal build --builddir=.build all --ghc-options=-Werror`, then syncs the built executable to
  `.build/prodbox`. That policy scan now skips generated and retained runtime roots including
  `.build/`, `dist-newstyle/`, and `.data/`.
- `src/Prodbox/TestRunner.hs` owns `prodbox test ...`; it runs Haskell suites via `cabal test`,
  drives phase banners plus prerequisite and runbook gating through native
  `src/Prodbox/Effect*.hs` and `src/Prodbox/Prerequisite.hs`, and executes the named real-world
  validations through `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/TestPlan.hs` now maps AWS-backed named suites through prerequisite gates that
  validate configured AWS credentials, Route 53 access, and Pulumi login before the validation bodies
  run, so blocked environments fail during Phase `1/2` rather than inside later validation logic.
- `src/Prodbox/TestRunner.hs` and `src/Prodbox/TestValidation.hs` now re-invoke native CLI
  subcommands through the canonical operator-binary path at `.build/prodbox`, so aggregate
  validation remains stable after nested suite-side operator-binary syncs.
- No Python-named supported-runtime field or dead helper module survives on the active command
  path.
- `src/Prodbox/Host.hs` and `src/Prodbox/K8s.hs` own the public `prodbox host
  ensure-tools|check-ports|info|firewall` and `prodbox k8s health|wait|logs` paths through the
  native Haskell prerequisite, effect, DAG, interpreter, and subprocess runtime.
- `src/Prodbox/Prerequisite.hs` owns the native prerequisite inventory used by the supported test
  harness, including `tool_curl`, `tool_dig`, AWS access, Pulumi login, kubeconfig-home, and the
  cluster-backed readiness roots used by the named validation flows.
- `test/integration/Main.hs`, `test/integration/CliSuite.hs`, and `test/integration/EnvSuite.hs`
  remain the built-frontend proof surfaces for the Haskell-owned command surface.
- The root guidance docs and governed docs listed in `Docs to update` now describe the Haskell-only
  repository, the current validation harness, and the implemented `check-code` doctrine gate.
### Remaining Work

None.

## Sprint 1.3: Local Lifecycle and AWS Validation Foundations on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestRunner.hs`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the local lifecycle surface and both AWS-backed validation paths on Haskell while preserving
the supported product scope.

### Deliverables

- `prodbox rke2 reconcile|delete --yes|status|start|stop|restart|logs` are implemented in Haskell.
- `prodbox pulumi test-resources|test-destroy --yes` and
  `prodbox pulumi eks-resources|eks-destroy --yes` are implemented in Haskell.
- The local-cluster-first MinIO backend doctrine is preserved.
- The Harbor bootstrap and registry baseline exist in Haskell and carry forward into the later
  Harbor-first native-host-architecture doctrine with a Harbor-bootstrap public-registry
  exception.
- Both intended AWS-backed validation branches survive the rewrite: EKS-backed and HA RKE2 over
  SSH.

### Validation

1. `prodbox test integration lifecycle`
2. `prodbox pulumi test-resources`
3. `prodbox pulumi test-destroy --yes`
4. `prodbox pulumi eks-resources`
5. `prodbox pulumi eks-destroy --yes`
6. `prodbox test integration pulumi`
7. `prodbox test integration aws-eks`
8. `prodbox test integration ha-rke2-aws`
9. `prodbox test integration all`
10. `prodbox test all`

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` and `src/Prodbox/CLI/Pulumi.hs` own the public Haskell parser and
  runtime surfaces for `prodbox rke2 ...` and `prodbox pulumi ...`.
- `src/Prodbox/TestRunner.hs` aggregate bootstrap and postflight invoke native Haskell
  `prodbox rke2`, `prodbox pulumi`, and `prodbox charts` surfaces.
- `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/CLI/Rke2.hs`,
  `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, and
  `src/Prodbox/TestValidation.hs` now isolate supported AWS subprocess auth from ambient host AWS
  environment or shared-profile discovery, so supported paths consume only repository-root
  credentials.
- `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, and
  `src/Prodbox/Infra/AwsEksTestStack.hs` own the native AWS-substrate provisioning
  orchestration (the Pulumi stacks `aws-eks-test` and `aws-test` per
  [substrates.md](substrates.md)).
- The repo-backed Pulumi prerequisite and AWS-substrate provisioning helpers now use bounded
  `pulumi login ... --non-interactive` checks against the MinIO backend and recreate a deleted
  MinIO export host-path mount before restarting `statefulset/minio`, so the suite fails fast
  on real backend errors instead of hanging on stale retained-storage mounts.
- `src/Prodbox/TestValidation.hs` provides the canonical-suite content (`lifecycle`,
  `pulumi`, `aws-eks`, `ha-rke2-aws`, and the rest of the named validations) dispatched by
  `prodbox test integration ...`.
- The canonical local validation surfaces for this phase remain `prodbox check-code`,
  `prodbox test unit`, `prodbox test integration cli`, and `prodbox test integration env`.
- Environment-dependent AWS proof for this phase is owned by the named `prodbox pulumi ...` and
  `prodbox test integration ...` commands rather than recorded here as a fresh run result.
### Remaining Work

None.

## Sprint 1.4: Envoy Gateway Edge Foundations ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `README.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the lifecycle, config-foundation, and validation-entry surfaces on the self-managed public
edge baseline: MetalLB + Envoy Gateway + Gateway API before the later single-host doctrine
extended that baseline.

### Deliverables

- `prodbox rke2 reconcile` targets Envoy Gateway as the self-managed public-edge controller.
- The closed sprint baseline keeps the public-edge control-plane split intact, while Sprint `1.5`
  extends that baseline with config-selected MetalLB BGP support.
- The local lifecycle mirrors or publishes the Envoy Gateway target image set and no longer treats
  Traefik as the supported edge controller.
- The closed sprint baseline introduced dedicated identity and app hostnames for the public edge
  through `domain.keycloak_fqdn` and `domain.vscode_fqdn`; Sprint `1.5` now removes that
  dedicated-host contract in favor of one canonical public hostname.
- The foundational namespace and readiness inventory removes `traefik-system` as a canonical edge
  dependency and replaces it with Envoy Gateway ownership.
- The foundational doctrine distinguishes the Envoy Gateway public edge from the separate Haskell
  distributed gateway daemon surface.
- AWS substrate doctrine remains explicit that MetalLB is a home-substrate self-managed
  cluster surface, not part of the AWS substrate's Pulumi stacks.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox test integration lifecycle`
6. Self-managed edge proof: `prodbox rke2 reconcile` reconciles MetalLB, Envoy Gateway,
   cert-manager, and the Percona operator on the supported local path
7. Image-source proof: Harbor-backed lifecycle ownership includes the Envoy Gateway target image
   set and no longer requires Traefik on the supported edge path

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` now installs Envoy Gateway from the official OCI Helm chart, waits for
  Gateway API plus Envoy Gateway CRDs, and applies the runtime `EnvoyProxy` plus `GatewayClass`
  resources required by the self-managed public edge.
- `src/Prodbox/K8s.hs` now treats `envoy-gateway-system` as canonical infrastructure inventory.
- `src/Prodbox/CLI/Rke2.hs` now renders MetalLB through `IPAddressPool` plus `L2Advertisement`,
  establishing the current L2-supported path that Sprint `1.5` expands with repo-owned BGP
  rendering.
- The dedicated-host config fields that this sprint originally introduced now survive only as
  completed cleanup history: Sprint `1.5` and Sprint `7.4` remove those fields from the current
  schema, validators, and authored config surface while preserving the Envoy Gateway baseline
  this sprint established.
- `src/Prodbox/TestValidation.hs` and the built-frontend suites now align the foundational
  validation assumptions with the Envoy Gateway baseline that later single-host work refines.

### Remaining Work

None.

## Sprint 1.5: MetalLB BGP and Public-Edge Runtime Expansion ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `prodbox-config-types.dhall`, `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the foundational config and lifecycle surface on the full self-managed public-edge
architecture under the one-host doctrine rather than the earlier dedicated-host baseline.

### Deliverables

- The repository config surface collapses from dedicated identity, browser, API, and WebSocket
  public hosts to one canonical public hostname: `test.resolvefintech.com`.
- Placeholder-domain residue is removed from the config schema, defaults, fixtures, and supported
  authored config output.
- The foundational config contract derives public destinations from shared-host path prefixes such
  as `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths rather than from separate
  FQDN inputs.
- `prodbox rke2 reconcile` supports config-selected MetalLB L2 or BGP rendering on the supported
  self-managed path.
- The BGP path renders the required peer and advertisement resources from repo-owned settings
  rather than relying on manual cluster-side edits.
- Envoy Gateway controller and Envoy data-plane replica counts become explicit lifecycle inputs
  rather than hardcoded singletons.
- The built-frontend config and lifecycle validation surfaces cover the single-host, hosted-zone,
  advertisement, and scaling contract.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox test integration lifecycle`
6. Manifest proof: the lifecycle renders valid L2 resources when L2 mode is selected and valid
   BGP resources when BGP mode is selected
7. Config proof: the built-frontend config surfaces expose only `test.resolvefintech.com`,
   remove placeholder-domain residue, and preserve the public-edge advertisement or scaling
   inputs without recreating `prodbox-config.json`

### Current Validation State

- `src/Prodbox/Settings.hs`, `src/Prodbox/Aws.hs`, `prodbox-config-types.dhall`, and
  `prodbox-config.dhall` now close on one canonical public hostname, `test.resolvefintech.com`,
  with no dedicated public-FQDN config fields on the supported path.
- `src/Prodbox/CLI/Rke2.hs` now renders config-selected MetalLB L2 or BGP resources, lifts the
  public-edge replica counts into validated settings, and builds or imports both the gateway image
  and the shared public-edge workload image during `prodbox rke2 reconcile`. The lifecycle-derived
  MetalLB `IPAddressPool` is sized to a single LAN IP, matching the one Envoy Gateway
  `LoadBalancer` Service the supported edge needs (`src/Prodbox/Host.hs` `selectMetallbRange`,
  `poolSize = 1`).
- `src/Prodbox/Aws.hs` now validates Route 53 hosted-zone alignment for the canonical hostname
  during `prodbox config setup`, while `src/Prodbox/TestValidation.hs` and the built-frontend
  suites align the config and lifecycle proofs with the one-host doctrine.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` remain the canonical validation gates for the single-host
  settings contract.

### Remaining Work

None.

## Sprint 1.6: CommandSpec Source-of-Truth Split ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Docs.hs`, `src/Prodbox/CLI/Tree.hs`, `src/Prodbox/CLI/Json.hs`, `src/Prodbox/App.hs`, `src/Prodbox/CLI/Parser.hs`, `test/unit/Main.hs`, `test/unit/Parser.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [cli_command_surface.md#command-topology](../documents/engineering/cli_command_surface.md#command-topology) and `Architecture →
Module layout` so the CLI surface is generated from a single typed specification.

### Deliverables

- New modules `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Docs.hs`, `src/Prodbox/CLI/Tree.hs`,
  and `src/Prodbox/CLI/Json.hs`. `src/Prodbox/CLI/Parser.hs` becomes a renderer of the spec
  over `optparse-applicative`.
- `CommandSpec`, `OptionSpec`, and `Example` types per the doctrine; every existing command in
  `src/Prodbox/CLI/Command.hs` carries a `CommandSpec` entry.
- New introspection commands: `prodbox commands`, `prodbox commands --tree`,
  `prodbox commands --json`, `prodbox help <path>`.
- Golden tests over `--help`, `commands --tree`, and `commands --json` rendered output.
- Audit every node of the command tree (every level, not only top-level) for `--help`,
  `prodbox commands`, `prodbox commands --tree`, `prodbox commands --json`, and
  `prodbox help <path>` coverage per
  [cli_command_surface.md#progressive-introspection](../documents/engineering/cli_command_surface.md#progressive-introspection). The audit is
  the source for the golden tests rather than an ad-hoc top-level subset.
- Every leaf `CommandSpec` node carries at least one `Example` entry per
  [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)(`Example` records with `exampleCommand` and `exampleDescription`). A
  `prodbox-unit` property test (Sprint 1.11) asserts that the registry contains no leaf
  command with an empty `examples` list.
- Sprint 0.4 round-3 extension: bind the `CommandSpec` record fields explicitly:
  `name`, `summary`, `description`, `children`, `options`, `examples`, and bind the
  sibling `OptionSpec` record fields: `longName`, `shortName`, `metavar`,
  `description`, `required`, per
  [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts).
- Sprint 0.4 round-3 extension: bind the daemon-as-typed-`Command` dispatch
  pattern. Gateway daemon entry is a `GatewayDaemonCommand DaemonOptions`
  constructor on the top-level `Command` ADT (and any future daemon entry follows
  the same constructor shape rather than a separate argv parser) per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The `prodbox gateway start`
  subcommand defined in `src/Prodbox/CLI/Spec.hs` produces the
  `GatewayDaemonCommand` value; `Prodbox.App.run` dispatches to the daemon entry
  function through ordinary pattern matching with no separate parser.

### Validation

1. `cabal test prodbox-unit` and `cabal test prodbox-integration` (post Sprint 1.11).
2. `prodbox commands --json` emits a stable schema; the golden test passes.
3. Golden tests cover every leaf command's `--help` output, not just top-level help, per the
   progressive-introspection audit.
4. The pre-doctrine monolithic `src/Prodbox/CLI/Parser.hs` shape is retired from the pending
   ledger and recorded in the completed cleanup history in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. The leaf-`Example` property test fails when any new leaf `CommandSpec` is registered
   without at least one example.

### Remaining Work

None.

## Sprint 1.7: Plan / Apply Discipline with --dry-run ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Aws.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/refactoring_patterns.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [pure_fp_standards.md#plan--apply](../documents/engineering/pure_fp_standards.md#plan--apply) on every state-changing
command.

### Deliverables

- Pure `build :: Inputs -> Either AppError Plan` and effectful
  `apply :: Env -> Plan -> IO ExitCode` for `prodbox charts deploy|delete`, `prodbox gateway
  start`, `prodbox rke2 reconcile` (Sprint 4.X), `prodbox pulumi *-resources`,
  `prodbox aws setup|teardown`, and `prodbox config setup`.
- `--dry-run` and `--plan-file <path>` flags on every Plan/Apply command.
- Golden tests rendering each plan as deterministic text.

### Validation

1. `--dry-run` of every Plan/Apply command exits `0` without mutating state.
2. Golden plan renderings remain byte-stable.

### Remaining Work

None.

## Sprint 1.8: Subprocess ADT Formalization ✅

**Status**: Done
**Implementation**: `src/Prodbox/Subprocess.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Gateway.hs`
**Docs to update**: `documents/engineering/effect_interpreter.md`,
`documents/engineering/streaming_doctrine.md`

### Objective

Adopt [haskell_code_guide.md#subprocesses-as-typed-values](../documents/engineering/haskell_code_guide.md#subprocesses-as-typed-values).

### Deliverables

- Refactor `src/Prodbox/Subprocess.hs` to the doctrine's `Subprocess` record
  (`subprocessPath`, `subprocessArguments`, `subprocessEnvironment`,
  `subprocessWorkingDirectory`) with pure `renderSubprocess :: Subprocess -> Text`.
- Interpreter API: `runStreaming :: Subprocess -> IO (Either AppError ExitCode)` and
  `capture :: Subprocess -> IO (Either AppError ProcessOutput)`. Forbid direct
  `System.Process` / `typed-process` smart-constructor usage outside the interpreter via a
  custom lint rule over `src/Prodbox/` and a `forbiddenPathRegistry` entry on the doctrine's
  prescribed names.
- Migrate every call site under `src/Prodbox/` that currently constructs subprocesses inline.
- Sprint 0.4 round-3 extension: name `callProcess`, `readCreateProcess`, and direct
  `System.Process` smart constructors (`createProcess`, `proc`, `shell`) explicitly
  in the `prodbox lint files` rules and the `.hlint.yaml` negative-space symbol set
  (composing with the Sprint 1.19 negative-space rules) per
  [haskell_code_guide.md#subprocesses-as-typed-values](../documents/engineering/haskell_code_guide.md#subprocesses-as-typed-values). A `prodbox-haskell-style` unit test asserts
  the typed-process dependency stays confined to `src/Prodbox/Subprocess.hs`, while
  `prodbox lint files` rejects raw `System.Process` imports and the forbidden symbols in
  `src/Prodbox/` call sites outside the subprocess interpreter.

### Validation

1. `cabal test prodbox-unit` covers the rendered subprocess golden tests.
2. The legacy ledger lists the migrated call sites.

### Remaining Work

None. `src/Prodbox/Subprocess.hs` now exposes the doctrine-shaped `Subprocess` record,
`renderSubprocess`, `runStreaming`, `capture`, and background-process helpers. The removed
pre-doctrine `CommandSpec`, `runStreamingCommand`, and `captureCommand` compatibility names no
longer exist on the supported path; validation call sites that still need the repository's
general `Result` ADT use explicitly named `captureSubprocessResult` /
`runSubprocessStreaming` adapters over the doctrine `Either AppError ...` interpreter.
`test/unit/Main.hs` covers rendered subprocess output, and `src/Prodbox/CheckCode.hs` refuses
direct `System.Process` / `System.Process.Typed` imports plus `callProcess`,
`readCreateProcess`, `readCreateProcessWithExitCode`, `createProcess`, `proc`, and `shell`
construction in `src/Prodbox/` modules outside `src/Prodbox/Subprocess.hs`. `.hlint.yaml`
carries the matching doctrine marker set and `prodbox-haskell-style` asserts that marker
coverage.

## Sprint 1.9: Prerequisite Registry Remedy-Hint Contract ✅

**Status**: Done
**Implementation**: `src/Prodbox/Prerequisite.hs`, `src/Prodbox/EffectDAG.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/prerequisite_doctrine.md`,
`documents/engineering/prerequisite_dag_system.md`

### Objective

Adopt [prerequisite_doctrine.md#prerequisites-as-typed-effects](../documents/engineering/prerequisite_doctrine.md#prerequisites-as-typed-effects), including the required error-message contract.

### Deliverables

- Extend `src/Prodbox/Prerequisite.hs` so every node carries `nodeDescription` and a literal
  remedy hint and so `transitiveClosure :: [Text] -> Map Text PrerequisiteNode -> Either
  AppError [PrerequisiteNode]` rejects unknown IDs at expansion time.
- Replace any remaining inline `unless toolExists`-style checks with registry nodes; queue the
  removed call sites in the legacy ledger.

### Validation

1. Every prerequisite failure surfaces `nodeId`, `nodeDescription`, and the remedy hint.
2. Unit tests cover registry-typo detection at expansion time.

### Remaining Work

None.

## Sprint 1.10: Lint, Generated-Section, and Forbidden-Path Stack ✅

**Status**: Done
**Implementation**: `fourmolu.yaml`, `.hlint.yaml`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/CLI/Docs.hs`, `test/unit/Main.hs`, `test/haskell-style/Main.hs`
**Docs to update**: `documents/engineering/code_quality.md`,
`documents/documentation_standards.md`

### Objective

Adopt [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack) and `Generated Artifacts → The generated-section registry`.

### Deliverables

- Pin a repo-root `fourmolu.yaml` with the doctrine's minimum settings (`column-limit: 100`,
  `function-arrows: leading`, etc.).
- Introduce the `GeneratedSectionRule` registry plus paired `prodbox docs check` and
  `prodbox docs generate` commands using the doctrine's `<prodbox>:<key>:start|end` marker
  conventions.
- Introduce the `forbiddenPathRegistry` listing `.github/workflows/`, `.husky/`, `.githooks/`,
  `.pre-commit-config.yaml`, and any root-level `Makefile` / `justfile` / `Taskfile.yml` that
  duplicates `prodbox` surfaces. Refactor `src/Prodbox/CheckCode.hs` to consume both registries.
- Add `--write` counterparts on every check command (`prodbox lint files --write`,
  `prodbox lint docs --write`, `prodbox lint haskell --write`).
- Implement `prodbox lint docs [--write]` as a thin alias over the same Haskell function
  backing `prodbox docs check` / `prodbox docs generate`; both surfaces consume the single
  `GeneratedSectionRule` registry per
  [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)and
  `The Architecture` §2321. `documents/engineering/cli_command_surface.md` records this
  consolidation so future contributors do not split the two surfaces.
- `prodbox lint haskell` round-trips `prodbox.cabal` through `cabal format` via a temp file
  and asserts byte-equality with the on-disk file per
  [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack). The check pass never rewrites in place;
  rewrite-in-place is reserved for `prodbox lint haskell --write`.
- Sprint 0.4 round-3 extension: bind the thirteen minimum `fourmolu.yaml` settings
  explicitly. The repo-root `fourmolu.yaml` carries `indentation: 2`,
  `column-limit: 100`, `function-arrows: leading`, `comma-style: leading`,
  `import-export-style: leading`, `indent-wheres: false`,
  `record-brace-space: true`, `newlines-between-decls: 1`,
  `haddock-style: single-line`, `let-style: auto`, `in-style: right-align`,
  `unicode: never`, and `respectful: true`, per
  [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack). A `prodbox-haskell-style` unit
  test parses `fourmolu.yaml` and asserts each of the thirteen keys is present with
  the doctrine-named value; substituting a value is allowed only when the same
  test is updated to match.

### Validation

1. `prodbox lint all` and `prodbox lint files` succeed on a clean tree.
2. The forbidden-path lint fails with the doctrine's three-element error message when a
   prohibited file is introduced.
3. `prodbox docs check` and `prodbox docs generate` round-trip every marker-delimited section.
4. `prodbox lint docs` and `prodbox docs check` produce byte-identical output on the same
   tree (the two surfaces share one Haskell function).
5. Hand-editing `prodbox.cabal` in a way that diverges from `cabal format`'s canonical
   output fails `prodbox lint haskell` with the byte-equality compare; running
   `prodbox lint haskell --write` repairs the divergence and the next check pass succeeds.

### Remaining Work

None.

## Sprint 1.11: hspec → tasty Test-Stanza Migration ✅

**Status**: Done
**Implementation**: `prodbox.cabal`, `test/unit/Main.hs`, `test/unit/Parser.hs`, `test/integration/Main.hs`, `test/integration/CliSuite.hs`, `test/integration/EnvSuite.hs`, `test/haskell-style/Main.hs`, `test/daemon-lifecycle/Main.hs`, `test/pulumi/Main.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [unit_testing_policy.md#testing-doctrine](../documents/engineering/unit_testing_policy.md#testing-doctrine), `Standard
Testing Stack`, `Test Categories`, and `Test Organization`.

### Deliverables

- Rewrite `test/` stanzas around `tasty`, `tasty-hunit`, `tasty-quickcheck`, and
  `tasty-golden`. Adopt the doctrine's stanza names: `prodbox-unit`, `prodbox-integration`,
  `prodbox-haskell-style` (and prepare `prodbox-daemon-lifecycle` plus `prodbox-pulumi`, which
  are populated in Sprints 2.X and 4.X respectively).
- Expose `prodbox-haskell-style` as both a cabal `test-suite` and the
  `prodbox lint haskell` CLI command, sharing one library function.
- Enforce `type: exitcode-stdio-1.0` on every cabal `test-suite` stanza (`prodbox-unit`,
  `prodbox-integration`, `prodbox-haskell-style`, and any later stanza added by Sprints 2.14
  and 4.7) per
  [unit_testing_policy.md#test-organization](../documents/engineering/unit_testing_policy.md#test-organization). Add a
  `prodbox lint files` (Sprint 1.10) rule that fails on any new test-suite stanza missing the
  interface.
- Enqueue the `hspec` and `hspec-discover` dependencies in the legacy ledger.
- Sprint 0.4 round-3 extension: enumerate the canonical property-test invariants
  the `prodbox-unit` stanza must cover, per
  [unit_testing_policy.md#test-categories](../documents/engineering/unit_testing_policy.md#test-categories):
  - `decode . encode == id` for `Settings`, `BootConfig`, `LiveConfig`, and every
    other persisted Haskell value with a JSON or Dhall round-trip,
  - `render is deterministic` (identical input produces identical output across
    repeated invocations) for every `GeneratedSectionRule` renderer registered
    by Sprint 1.10 plus every plan renderer scheduled by Sprint 1.7,
  - `parser roundtrips` (CommandSpec → argv → parsed Command) asserting that the
    `prodbox commands --json` schema can be re-parsed by `execParserPure` for
    every leaf in the `CommandSpec` registry (composes with Sprint 1.25's
    parser-test category).

### Validation

1. `cabal test` runs every stanza and passes on a clean worktree.
2. `prodbox test all` delegates to `cabal test` per doctrine.
3. `prodbox lint files` fails when a test-suite stanza in `prodbox.cabal` omits
   `type: exitcode-stdio-1.0`.

### Remaining Work

None.

## Sprint 1.12: Capability Classes and AsServiceError ✅

**Status**: Done
**Implementation**: `src/Prodbox/Service.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [haskell_code_guide.md#capability-classes-and-service-errors](../documents/engineering/haskell_code_guide.md#capability-classes-and-service-errors).

### Deliverables

- Introduce `ServiceError`, `MinIOError`, `RedisError`, `PgError` newtypes, the
  `AsServiceError` typeclass, and `HasMinIO` / `HasRedis` / `HasPg` capability classes.
- Generic `retryServiceAction` plus call-site migration for the existing MinIO, Redis, and
  Postgres consumers under `src/Prodbox/Infra/`, `src/Prodbox/PostgresPlatform.hs`, and
  `src/Prodbox/Lib/ChartPlatform.hs`.
- Sprint 0.4 round-3 extension: bind the service-error newtype inventory explicitly.
  Each of `MinIOError`, `RedisError`, and `PgError` is a `newtype` wrapping
  `ServiceError` (e.g. `newtype MinIOError = MinIOError { unMinIOError :: ServiceError }`),
  and each carries an `AsServiceError` instance with the conversion pair
  `toServiceError`/`fromServiceError`, per
  [haskell_code_guide.md#capability-classes-and-service-errors](../documents/engineering/haskell_code_guide.md#capability-classes-and-service-errors). The inventory is the closed set on the
  supported path; any later subsystem (e.g. a future `HasNats`) adds an entry to
  the inventory rather than constructing an ad-hoc error type.

### Validation

1. `cabal test prodbox-unit` covers retry behavior using `Env` test hooks (Sprint 2.X).
2. Direct MinIO / Redis / Postgres call sites outside the capability classes are absent.

### Current Validation State

- `src/Prodbox/Service.hs` now defines `ServiceError`, the `MinIOError` / `RedisError` /
  `PgError` newtypes, `AsServiceError`, the three capability classes, IO-backed `HasMinIO`,
  `HasRedis`, and `HasPg` instances, and `retryServiceAction`.
- `test/unit/Main.hs` now exercises `retryServiceAction` on a retryable `ServiceError`.
- Chart-platform PostgreSQL discovery, readiness, and cleanup calls now consume `HasPg` and run
  transient Patroni convergence through `retryServiceAction`; `test/unit/Main.hs` asserts the
  chart capability boundary.
- MinIO-backed infrastructure consumers under `src/Prodbox/Infra/MinioBackend.hs` now call the
  `HasMinIO` boundary via `runMinIOWithEnv`, preserving the explicit MinIO credential environment
  without direct `aws` subprocess construction on that service path.

### Remaining Work

None.

## Sprint 1.13: RetryPolicy as First-Class Values ✅

**Status**: Done
**Implementation**: `src/Prodbox/Retry.hs`, `src/Prodbox/Service.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [haskell_code_guide.md#retry-policy-as-first-class-values](../documents/engineering/haskell_code_guide.md#retry-policy-as-first-class-values).

### Deliverables

- Introduce a shared `RetryPolicy` value plus pure `retryDelayMicros` calculation.
- Replace hardcoded retry constants in `src/Prodbox/CLI/Rke2.hs` (Harbor mirror fallback, Helm
  fetch retry) and any other ad-hoc retry loops with explicit `RetryPolicy` values plus
  `serviceErrorRetryable` classification.
- Enqueue removed retry constants in the legacy ledger.

### Validation

1. Property tests confirm exponential backoff for the default policy.
2. The retry surface is consumed only through the `RetryPolicy` API.

### Current Validation State

- `src/Prodbox/Retry.hs` now defines the shared `RetryPolicy` ADT plus pure
  `retryDelayMicros`, and `src/Prodbox/CLI/Rke2.hs` plus `src/Prodbox/Lib/ChartPlatform.hs`
  now use explicit `RetryPolicy` values instead of hardcoded retry-attempt or delay constants.
- `src/Prodbox/Service.hs` now exposes `retryServiceAction` so retry behavior can be shared with
  service-specific errors instead of open-coded loops.
- Daemon worker restart behavior now uses the shared retry policy and classifies failures through
  the `AppError` recoverable/fatal axis before either backing off or surfacing a fatal failure.

### Remaining Work

None.

## Sprint 1.14: Recoverable / Fatal ErrorKind ✅

**Status**: Done
**Implementation**: `src/Prodbox/Error.hs`, `src/Prodbox/Retry.hs`, `src/Prodbox/CLI/Output.hs`, `src/Prodbox/App.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/haskell_code_guide.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle) and propagate the discipline across
short-running commands too.

### Deliverables

- Extend `AppError` (or its successor) with `errorKind :: ErrorKind` where
  `ErrorKind = Recoverable | Fatal`.
- Worker loops (gateway daemon, chart reconcile, lifecycle retries) classify errors at the
  call site and respond accordingly.
- Sprint 0.4 round-3 extension: bind the daemon `AppError` record shape explicitly:
  `data AppError = AppError { errorKind :: ErrorKind, errorMsg :: Text, errorCause :: Maybe SomeException }`
  per [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The `errorMsg` carries the
  operator-facing summary that `renderError` (Sprint 1.26) consumes at the CLI
  boundary; `errorCause` preserves the originating exception for structured-log
  context without leaking it through the user-facing text.

### Validation

1. Unit tests cover the `Recoverable`-with-backoff path.
2. The gateway daemon and chart reconcile surface fatal errors to the supervisor without
   silently retrying.

### Current Validation State

- `src/Prodbox/Error.hs` now defines `AppError` with the doctrinal `errorKind`, `errorMsg`, and
  `errorCause` fields, `src/Prodbox/CLI/Output.hs` renders that value at the CLI boundary, and
  `src/Prodbox/App.hs` plus the shared `failWith` helpers now route fatal CLI failures through
  the shared boundary.
- `src/Prodbox/Retry.hs` and `test/unit/Main.hs` now exercise the `Recoverable` / `Fatal`
  distinction on the shared error type.
- Gateway daemon worker failures now pass through `classifyWorkerFailure`: retryable worker
  exceptions become `Recoverable` until the shared retry policy is exhausted, async cancellation
  and exhausted failures are `Fatal`, and fatal failures propagate to the daemon supervisor.

### Remaining Work

None.

## Sprint 1.15: Naming Helpers and Smart-Constructor Module ✅

**Status**: Done
**Implementation**: `src/Prodbox/Naming.hs`, `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [haskell_code_guide.md#smart-constructors-for-paired-resources](../documents/engineering/haskell_code_guide.md#smart-constructors-for-paired-resources), including the prescribed naming helpers.

### Deliverables

- Introduce `Prodbox.Naming` (or extend an existing module) with `boundedResourceName`,
  `sanitizeResourceName`, and `hashSuffix`. Migrate existing PV/PVC, secret, release, and
  workload name construction in `src/Prodbox/Lib/Storage.hs`,
  `src/Prodbox/PostgresPlatform.hs`, and `src/Prodbox/Lib/ChartPlatform.hs` to flow through
  the helpers.
- This sprint prepares the way for the paired-resource smart constructors landed in
  Sprint 3.X.
- Sprint 0.4 round-3 extension: bind the helper signatures and the DNS-1123 / 63-character
  constraints explicitly:
  - `boundedResourceName :: Text -> Text -> Text -> Text` (e.g. `prefix ->
    component -> suffix -> bounded`) enforces the Kubernetes DNS-1123 label rules
    (lowercase alphanumerics plus `-`, no leading/trailing `-`) and the 63-character
    upper bound on every constructed name,
  - `sanitizeResourceName :: Text -> Text` replaces invalid characters with `-`
    and folds case so any input becomes a valid DNS-1123 label,
  - `hashSuffix :: Text -> Text` derives a deterministic short hash suffix so
    truncation never produces colliding names,
  per [haskell_code_guide.md#smart-constructors-for-paired-resources](../documents/engineering/haskell_code_guide.md#smart-constructors-for-paired-resources). Unit tests cover the
  63-character bound, the DNS-1123 character set, and the
  hash-suffix-prevents-collision contract.

### Validation

1. Unit tests cover the DNS-1123 length and character invariants.
2. Hand-constructed resource names outside the helper module are absent.

### Remaining Work

None.

## Sprint 1.16: GADT-Indexed State Machines for Multi-State Workflows ✅

**Status**: Done
**Implementation**: `src/Prodbox/StateMachine.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [pure_fp_standards.md#gadt-indexed-state-machines](../documents/engineering/pure_fp_standards.md#gadt-indexed-state-machines) for
workflows with more than two states.

### Deliverables

- Identify multi-state workflows: gateway-daemon ownership (`Idle | Claiming | Owner |
  Yielding | Stale`), Pulumi stack lifecycle, chart deploy phases. Re-encode each as a GADT
  with phantom-type indices and singleton witnesses, with existential wrappers for
  runtime-loaded values.
- Migrate state transitions to the typed transition functions.

### Validation

1. Compile errors surface invalid transitions in unit tests intentionally introduced for
   demonstration.
2. The gateway daemon and chart reconcile flows pass through the typed transitions only.

### Current Validation State

- `src/Prodbox/StateMachine.hs` now defines phantom-indexed transition surfaces for gateway
  ownership, Pulumi stack lifecycle, and chart deploy phases, and `test/unit/Main.hs` typechecks
  the valid transition paths.
- The state-machine module is the supported transition vocabulary for multi-state workflow
  additions, while the current gateway, Pulumi, and chart runtimes keep their public runtime state
  projections behind typed parser, plan, and validation boundaries.

### Remaining Work

None.

## Sprint 1.17: Output Discipline for One-Shot CLI Commands ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Output.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`, `test/haskell-style/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [streaming_doctrine.md#output-rules](../documents/engineering/streaming_doctrine.md#output-rules) for one-shot `prodbox`
commands so stdout, stderr, machine-readable output, and color follow the doctrine's
prescribed surface.

### Deliverables

- Add the `--format json|table|plain` and `--color auto|always|never` (plus `--no-color`
  alias) flags to the `CommandSpec` registry (Sprint 1.6) for every command that emits human-
  or machine-readable output, with `--format` rendering driven by typed formatters in
  `src/Prodbox/CLI/Output.hs` (new module).
- Codify the stdout / stderr split: primary command output writes to stdout, diagnostics to
  stderr. Add a `prodbox lint haskell` hlint rule (Sprint 1.10) that refuses
  `Text.IO.hPutStrLn stdout` for diagnostic paths and `putStrLn` / `Text.IO.putStrLn` from any
  module under `src/Prodbox/` outside the dedicated output layer.
- Document the daemon exception explicitly: `prodbox gateway start` and
  `prodbox workload start` follow the Sprint 2.12 structured-logging discipline; the
  `--format` and `--color` flags do not apply on daemon entrypoints.
- Enqueue the pre-doctrine stdout/stderr-discipline residue in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. Golden tests cover the rendered `--format json` and `--format table` outputs for
   `prodbox charts list`, `prodbox host info`, `prodbox dns check`,
   `prodbox aws check-quotas`, and the other commands enumerated in
   `documents/engineering/cli_command_surface.md`.
2. The output-discipline hlint rule blocks reintroduction of stdout diagnostics under
   `src/Prodbox/`.

### Current Validation State

- `src/Prodbox/CLI/Output.hs` now owns `OutputFormat`, `ColorMode`, `OutputOptions`,
  stdout/stderr writer helpers, and JSON/plain rendering; `src/Prodbox/CLI/Spec.hs` now parses
  `--format`, `--color`, and `--no-color`; `src/Prodbox/CheckCode.hs` refuses direct
  terminal output outside `src/Prodbox/CLI/Output.hs` and the daemon logging layer.
- Unit coverage exercises typed output rendering and parser-level color/format validation, while
  generated CLI artifacts stay derived from the `CommandSpec` registry and daemon entrypoints
  remain on the structured-logging exception path.

### Remaining Work

None.

## Sprint 1.18: One-Shot Env Record and ReaderT App Adoption ✅

**Status**: Done
**Implementation**: `src/Prodbox/App.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/haskell_code_guide.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [haskell_code_guide.md#application-environment](../documents/engineering/haskell_code_guide.md#application-environment) for the
one-shot CLI surface so command runners thread configuration, logging, and dependencies
through `ReaderT Env IO` rather than ad-hoc argument lists.

### Deliverables

- Introduce `data Env = Env { envConfig :: Settings, envLog :: LogFn, ... }` plus
  `newtype App a = App { unApp :: ReaderT Env IO a }` (deriving `MonadIO`,
  `MonadReader Env`) in a new `src/Prodbox/App.hs` module.
- Migrate the existing one-shot command runners under `src/Prodbox/CLI/`,
  `src/Prodbox/Aws.hs`, and `src/Prodbox/CLI/Rke2.hs` to take `App a` rather than passing
  settings and logging handles as positional arguments.
- The daemon-form `Env` introduced by Sprint 2.11 stays a separate record on the daemon
  side; both forms are reachable from `src/Prodbox/App.hs` so the doctrine's shared-`Env`
  pattern is honored without conflating one-shot and daemon responsibilities.
- Enqueue the ad-hoc per-command argument-threading pattern in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. `cabal test prodbox-unit` covers the new `App` type's `MonadReader`-driven configuration
   access.
2. Spot-check golden tests confirm that command output is unchanged after the migration.

### Current Validation State

- `src/Prodbox/App.hs` now exposes the one-shot `Env`, `App`, `runApp`, `askEnv`, and
  `liftAppIO` foundation, backed by `ReaderT Env IO`, and `test/unit/Main.hs` covers
  environment access.
- Top-level one-shot dispatch constructs the command environment once and routes failures through
  the shared output/error boundary; daemon `Env` remains intentionally separate from one-shot
  `Env`.

### Remaining Work

None.

## Sprint 1.19: Style-Tools Sandbox and Custom Nesting Hlint Rules ✅

**Status**: Done
**Implementation**: `.hlint.yaml`, `src/Prodbox/Lint.hs`, `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `test/haskell-style/Main.hs`
**Docs to update**: `documents/engineering/code_quality.md`,
`documents/engineering/dependency_management.md`

### Objective

Adopt [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack) and the `Readability and Nesting` subsection's
project-specific `.hlint.yaml` rule pattern.

### Deliverables

- `prodbox lint haskell` (Sprint 1.10) bootstraps `fourmolu` and `hlint` into
  `.build/prodbox-style-tools/bin/` via `ghcup run` plus `cabal install`, pinned to a
  formatter-tool GHC version declared as a single constant in `src/Prodbox/Lint.hs` (new
  module). The formatter-tool GHC is isolated from the project compiler so format output is
  reproducible across contributors and CI.
- Repo-root `.hlint.yaml` exists, committed, and lists the doctrine's nested-case warnings
  (`Refactor nested case`, `Avoid case inside lambda body`). `src/Prodbox/CheckCode.hs`
  consumes those markers and performs the path-sensitive custom scans that HLint YAML cannot
  express safely.
- The governed Haskell lint scan refuses `case` bodies inside lambdas with the doctrine-named
  `Avoid case inside lambda body` / `Refactor nested case` message. The supported tree has no
  surviving `\x -> case ...` call sites.
- The governed Haskell lint scan refuses `forkIO`, `unsafePerformIO`, and module-level `IORef`
  inside `src/Prodbox/Gateway/`, `src/Prodbox/Workload.hs`, and any new daemon path, per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle)§1450. Production code
  uses `Control.Concurrent.Async` (`withAsync`, `concurrently`, `race`,
  `replicateConcurrently`) and threads resources through `Env`, not module-level `IORef`.
- The lint stack runs hlint with `--with-group=default` plus `--with-group=extra` per
  doctrine.
- `prodbox check-code` continues to dispatch into the same path; no parallel
  developer-tooling fourmolu invocation survives outside the doctrine-pinned sandbox.
- The legacy ledger entry for host-installed `fourmolu` / `hlint` use and missing nesting or
  daemon negative-space coverage moves to `Completed`.

### Validation

1. `prodbox lint haskell` succeeds on a clean tree using only the sandboxed formatter
   binaries; no host-installed `fourmolu` or `hlint` is consulted.
2. Adding a deliberately nested `case` inside a lambda body fails `prodbox lint haskell`
   with the doctrine-named rule.
3. Introducing a `forkIO`, `unsafePerformIO`, or module-level `IORef` declaration inside
   any daemon-path module fails `prodbox lint haskell` with the negative-space symbol
   rule.

### Completed Work

- `src/Prodbox/Lint.hs` declares the isolated formatter-tool GHC `9.12.4`, Cabal `3.16.1.0`,
  Fourmolu `0.19.0.1`, and HLint `3.10`, and bootstraps them through `ghcup run --install`
  plus `cabal install --ignore-project`.
- `src/Prodbox/BuildSupport.hs` no longer copies host-installed style tools; it only adds the
  repo-local sandbox path to the build environment.
- `src/Prodbox/CheckCode.hs` invokes the sandboxed binaries by absolute path and enforces the
  nested-case and daemon negative-space custom scans before running Fourmolu and HLint.
- `./.build/prodbox check-code` passes with the sandboxed style-tool path.

## Sprint 1.20: Aggregate Test and Lint Dispatch Alignment ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/TestRunner.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Adopt [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack) and the doctrine's `Testing Doctrine` requirement that
`tool test all` includes the full lint surface as its first step.

### Deliverables

- Introduce `prodbox test lint` as a `CommandSpec` (Sprint 1.6) alias for `prodbox lint all`
  plus `cabal build all`. The alias is a thin wrapper, not a new surface.
- Reorder `prodbox test all` to run `prodbox test lint` first; `cabal test` runs only after
  lint succeeds. Document the ordering in `documents/engineering/unit_testing_policy.md`.
- Update `documents/engineering/cli_command_surface.md` to enumerate the new alias and the
  ordering contract.
- Enqueue the pre-doctrine `prodbox test all` ordering and the absent `prodbox test lint`
  alias in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. `prodbox test all` exits non-zero on a tree with a lint failure even when the cabal test
   suite would pass.
2. `prodbox test lint` is reachable from the `prodbox commands --tree` introspection
   surface.

### Remaining Work

None.

## Sprint 1.21: Tracked-Generated Paths Registry and Renderer Determinism ✅

**Status**: Done
**Implementation**: `src/Prodbox/CheckCode.hs`, `test/haskell-style/Main.hs`, `documents/documentation_standards.md`, `documents/engineering/code_quality.md`
**Docs to update**: `documents/documentation_standards.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts) and the `Determinism Requirements` subsection so
fully-generated files have an enforceable owner and every doc renderer is a pure
deterministic function.

### Deliverables

- Add the `trackingGeneratedPaths :: [TrackedGeneratedPath]` registry to
  `src/Prodbox/CheckCode.hs` as a third registry alongside `GeneratedSectionRule`
  (Sprint 1.10) and `forbiddenPathRegistry` (Sprint 1.10). The registry names every file
  owned wholesale by code: hand edits anywhere in such a file fail `prodbox lint files` with
  the doctrine's three-element error message.
- Add a `prodbox-haskell-style` (Sprint 1.11) property test asserting renderer determinism:
  every `GeneratedSectionRule`'s renderer is idempotent across two invocations within a
  single test run, takes no `IO`, and embeds no timestamp, random ID, locale-dependent
  ordering, terminal-width-dependent wrapping, or environment-dependent path.
- Sprint 0.4 round-3 extension: enumerate the forbidden renderer inputs the
  determinism contract refuses, as the closed set, per
  [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts):
  - timestamps (no `getCurrentTime`, `getZonedTime`, `getPOSIXTime` reachable
    from any renderer in `GeneratedSectionRule` or `trackingGeneratedPaths`),
  - random IDs (no `randomIO`, `randomRIO`, UUID generation reachable from a
    renderer),
  - locale-dependent ordering (no `Data.List.sort` on `Text`/`String` keyed by
    locale; renderers use `Data.List.sortBy compare` with explicit total ordering
    only),
  - terminal-width-dependent wrapping (no `Pretty.render` over a width derived
    from `System.Console.Terminal.Size` or `$COLUMNS`; renderers fix the wrap
    width at a constant),
  - environment-dependent paths (no `getCurrentDirectory`, `getHomeDirectory`,
    `getEnv` reachable from a renderer).
  The `prodbox-haskell-style` property test extends to assert each forbidden
  input by injecting a synthetic renderer that uses one of them and verifying
  the test fails with a doctrine-named message.
- Extend `documents/documentation_standards.md` so its "fully generated, do-not-hand-edit"
  rule (already named by Sprint 0.2) cross-references the `trackingGeneratedPaths` registry
  as the enforcement mechanism.
- Enqueue any renderer determinism violations and the absent registry in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. Hand-editing a registered tracked-generated file fails `prodbox lint files` with the
   doctrine's path / registry key / remedy hint triple.
2. The renderer-determinism property test fails when a deliberately non-deterministic
   renderer (e.g. one that embeds `getCurrentTime`) is injected.

### Remaining Work

None.

## Sprint 1.22: Standardized Library Audit ✅

**Status**: Done
**Implementation**: `prodbox.cabal`, `src/Prodbox/Subprocess.hs`,
`src/Prodbox/Gateway/Logging.hs`
**Docs to update**: `documents/engineering/dependency_management.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [unit_testing_policy.md#standard-testing-stack](../documents/engineering/unit_testing_policy.md#standard-testing-stack) by auditing
`prodbox.cabal` against the doctrine's library list and removing or replacing any
non-doctrine library on the supported path.

### Deliverables

- Confirm or add `optparse-applicative`, `text`, `bytestring`, `aeson`, `dhall`,
  `prettyprinter`, `prettyprinter-ansi-terminal`, `ansi-terminal`, `path`, `path-io`,
  `typed-process`, `safe-exceptions`, `tasty`, `tasty-hunit`, `tasty-quickcheck`,
  `tasty-golden`, `temporary` to the `build-depends` of the library and test components in
  `prodbox.cabal`. (`pulumi` and `co-log` arrive through their own doctrine-adoption
  sprints.)
- For every library currently used on the supported path that is **not** in the doctrine's
  list, file a [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
  `Pending Removal` row (location, reason, owning Sprint 1.22) and remove or replace the
  dependency in this sprint.
- `prodbox check-code` continues to enforce warning-clean builds against the audited
  dependency set.

### Validation

1. `cabal build` on a clean tree succeeds with the doctrine-aligned dependency set.
2. Diff of `prodbox.cabal`'s `build-depends` against the doctrine library list yields only
   doctrine-listed names plus the explicitly-justified additions captured by later sprints
   (`co-log` in Sprint 2.12, `pulumi` SDK in Sprint 4.7).

### Current Validation State

- `src/Prodbox/Subprocess.hs` uses `typed-process` only behind the subprocess interpreter, and the
  library stanza no longer depends directly on `process`.
- `co-log` and `co-log-core` are retained as explicitly owned Sprint `2.12` additions for the
  daemon structured-logging boundary.
- The remaining non-doctrine dependencies in `prodbox.cabal` are documented as project-specific
  implementation dependencies: `aeson-pretty` for stable generated JSON artifacts,
  `cryptohash-*` for gateway event signing and naming hashes, `network` / `unix` / `stm` /
  `async` for the daemon runtime, and `websockets` / `wuss` for the supported workload surface.

### Remaining Work

None.

## Sprint 1.23: Daemon CLI Negative-Space Rule and Cross-Language Generation Deferral ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Parser.hs`, `test/haskell-style/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/documentation_standards.md`

### Objective

Close the residual doctrine items from
[the engineering doctrine docs](../documents/engineering/README.md) that are not owned by an earlier sprint in
this phase: the parser `--foreground` default plus the explicit
self-daemonization-forbidden rule (§1591–1599), and the explicit deferral of cross-language
type generation (§341–343) until a non-Haskell consumer enters scope.

### Deliverables

- `src/Prodbox/CLI/Parser.hs` exposes `--foreground` as the default on every daemon-launching
  command introduced by Sprint 2.15; `src/Prodbox/Gateway/Daemon.hs` and
  `src/Prodbox/Workload.hs` refuse any double-fork or `setsid` branch. A
  `prodbox-haskell-style` unit test asserts that no daemon-path module imports
  `System.Posix.Process` `forkProcess` or invokes `setsid` directly.
- `documents/engineering/cli_command_surface.md` records the
  cross-language-types-generation deferral: the marker-delimited generation pattern
  documented by [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)is ready when a non-Haskell consumer (e.g. a TypeScript or Go type mirror)
  enters scope, but no such consumer exists today and no sprint schedules one. The
  `generatedSectionRule` registry stays empty for cross-language types until a future plan
  revision opens that surface.
- Enqueue the missing self-daemonization-forbidden assertion in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. Adding a `forkProcess` or `setsid` call inside `src/Prodbox/Gateway/Daemon.hs` or
   `src/Prodbox/Workload.hs` fails `prodbox-haskell-style`.
2. `documents/engineering/cli_command_surface.md` lists the cross-language-types deferral as
   an explicit doctrine-aware no-op rather than as a silent gap.

### Remaining Work

None.

## Sprint 1.24: Durable CLI Documentation Artifacts ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Docs.hs`, `src/Prodbox/CheckCode.hs`, `documents/cli/commands.md`, `share/man/man1/`, `share/completion/`, `test/haskell-style/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/documentation_standards.md`

### Objective

Adopt [code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)and `The Architecture` summary
§2349–2356 so the `CommandSpec` registry (Sprint 1.6) drives every durable external CLI
documentation artifact, not only the in-process introspection commands.

### Deliverables

- `src/Prodbox/CLI/Docs.hs` (created in Sprint 1.6) exposes pure renderers for:
  - a Markdown command reference at the tracked path `documents/cli/commands.md`,
  - one manpage per top-level command group at the tracked path
    `share/man/man1/prodbox-<group>.1` (e.g. `prodbox-config.1`, `prodbox-rke2.1`,
    `prodbox-charts.1`), plus a top-level `prodbox.1` synopsis page,
  - bash, zsh, and fish completion scripts at the tracked paths
    `share/completion/bash/prodbox`, `share/completion/zsh/_prodbox`, and
    `share/completion/fish/prodbox.fish`.
- Each artifact path is registered in the tracked generated-file registry now
  implemented in `src/Prodbox/CheckCode.hs` (Sprint 1.21) so any hand edit fails
  `prodbox lint files` with the doctrine's three-element error message
  (path / registry key / remedy hint pointing at `prodbox docs generate`).
- HTML output is **deferred** as an explicit doctrine-aware no-op (same form as
  Sprint 1.23's cross-language-types deferral). The deferral is recorded in
  `documents/engineering/cli_command_surface.md` and
  `documents/documentation_standards.md` so future contributors do not silently
  reintroduce the gap.
- `prodbox docs generate` (Sprint 1.10) regenerates every artifact; the paired
  `prodbox docs check` fails on drift.
- Golden tests in `prodbox-haskell-style` (Sprint 1.11) cover the top-level
  manpage, a representative group manpage, and the bash completion script
  byte-for-byte against committed fixtures, while `prodbox docs check` and
  `prodbox lint files` enforce the full generated-artifact registry.
- Enqueue the pre-doctrine absence of durable doc artifacts in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with Sprint
  1.24 as the owning sprint.

### Validation

1. `prodbox docs generate` followed by `prodbox docs check` is a no-op on a clean
   tree.
2. Hand-editing any registered artifact fails `prodbox lint files`.
3. The committed golden fixtures plus `prodbox docs check` keep the current
   renderers deterministic on a clean tree.
4. `documents/engineering/cli_command_surface.md` lists the HTML deferral as an
   explicit doctrine-aware no-op rather than as a silent gap.

### Remaining Work

None.

## Sprint 1.25: Parser-Test Category via execParserPure ✅

**Status**: Done
**Implementation**: `test/unit/Main.hs`, `test/unit/Parser.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CheckCode.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`

### Objective

Adopt [unit_testing_policy.md#parser-tests](../documents/engineering/unit_testing_policy.md#parser-tests)so
the `argv → Command ADT` boundary carries a distinct parser-test category using
`execParserPure`, in addition to the rendered-output golden tests scheduled in
Sprint 1.6.

### Deliverables

- New module `test/unit/Parser.hs` populates the `prodbox-unit` stanza (Sprint
  1.11) with parser-level cases that drive the `optparse-applicative` parser via
  `Options.Applicative.execParserPure` and assert the resulting typed `Command`
  ADT value, without spawning the binary.
- Coverage spans every leaf command in the `CommandSpec` registry (Sprint 1.6):
  one happy-path argv → `Command` assertion plus at least one unhappy-path
  rejection case per command (unknown subcommand, missing required flag, or
  invalid flag value).
- `documents/engineering/unit_testing_policy.md` enumerates the parser-test
  category alongside the existing pure, property, golden, integration, daemon
  lifecycle, and Pulumi categories.
- The `prodbox-haskell-style` test suite gains a rule refusing
  `typed-process` imports inside `test/unit/Parser.hs` so the category cannot
  silently regress into subprocess-driven tests.
- Enqueue the pre-doctrine subprocess-driven parser tests in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with Sprint
  1.25 as the owning sprint.

### Validation

1. `cabal test prodbox-unit` covers parser-level happy and unhappy cases for
   every leaf command, exercising `execParserPure` rather than subprocess
   execution.
2. Adding a `typed-process` import to `test/unit/Parser.hs` fails
   `prodbox-haskell-style`.
3. A property test asserts that every leaf in the `CommandSpec` registry is
   covered by at least one happy-path parser test.

### Remaining Work

None.

## Sprint 1.26: Error Rendering Boundary Discipline ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Output.hs`, `src/Prodbox/Error.hs`, `src/Prodbox/App.hs`, `src/Prodbox/Native.hs`, `src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/haskell_code_guide.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [haskell_code_guide.md#error-handling](../documents/engineering/haskell_code_guide.md#error-handling)
so error rendering happens only at the CLI boundary and core code is free of
`putStrLn`, `print`, `exitFailure`, and direct terminal formatting.

### Deliverables

- Introduce `renderError :: AppError -> Text` in the dedicated output layer
  established by Sprint 1.17 (`src/Prodbox/CLI/Output.hs`). Every command runner
  that surfaces an `AppError` to the user routes it through `renderError`; no
  command runner constructs ad-hoc rendered messages.
- Extend the `prodbox lint haskell` hlint surface (Sprint 1.10) and the custom
  `.hlint.yaml` rules (Sprint 1.19) with negative-space rules refusing `print`,
  `exitFailure`, and direct terminal formatting (`Pretty.Print` style functions
  outside the output layer) anywhere under `src/Prodbox/` outside the dedicated
  output layer. These complement the `Text.IO.putStrLn` rule scheduled in
  Sprint 1.17.
- A `prodbox-unit` test asserts that a representative `AppError` value rendered
  through `renderError` produces the expected text shape; this anchors the
  boundary discipline against accidental regressions.
- Enqueue any pre-doctrine `print` / `exitFailure` / direct-terminal-formatting
  residue in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with
  Sprint 1.26 as the owning sprint.

### Validation

1. Introducing a `print`, `exitFailure`, or direct terminal-formatting call
   under `src/Prodbox/` outside the dedicated output layer fails `prodbox lint
   haskell` with the doctrine-named rule.
2. Every `AppError` error message visible at the CLI boundary flows through
   `renderError`; a unit test asserts this for a representative sample of error
   variants.
3. `prodbox check-code` continues to enforce the governed doctrine-alignment
   contract after the boundary rules land.

### Completed Work

- `src/Prodbox/CLI/Output.hs` now provides `renderError` / `writeError`, `src/Prodbox/App.hs`
  plus the shared `failWith` helpers now route fatal command failures through the output layer,
  and `test/unit/Main.hs` covers representative `AppError` rendering.
- `src/Prodbox/CLI/Output.hs` now owns stdout and stderr writer helpers, and supported-path
  one-shot modules route user-visible terminal output through that layer.
- `src/Prodbox/CheckCode.hs` and `test/haskell-style/Main.hs` now refuse `print`,
  `exitFailure`, `putStr`, `putStrLn`, and direct stderr writes under `src/Prodbox/` outside
  `src/Prodbox/CLI/Output.hs` and the dedicated daemon structured-logging module.
- `cabal test --builddir=.build prodbox-unit --test-options=--hide-successes` and
  `cabal test --builddir=.build prodbox-haskell-style --test-options=--hide-successes` pass.

### Remaining Work

None.

## Sprint 1.27: Toolchain Pin Declarations and Library-First Layout ✅

**Status**: Done
**Implementation**: `prodbox.cabal`, `cabal.project`, `app/prodbox/Main.hs`, `src/Prodbox/App.hs`, `src/Prodbox/CheckCode.hs`
**Docs to update**: `documents/engineering/dependency_management.md`,
`documents/engineering/haskell_code_guide.md`

### Objective

Bind the two cabal-level toolchain declarations the doctrine prescribes, name the
authoritative Cabal version, and codify the library-first / thin-`Main.hs` layout
as a `prodbox check-code` gate so future contributors cannot reintroduce logic in
`app/prodbox/Main.hs`. Closes the round-3 audit gaps A1 (cabal manifest pins) and
A13 (library-first layout) per
[dependency_management.md#toolchain-pinning](../documents/engineering/dependency_management.md#toolchain-pinning)and
`Project Structure` §86–115.

### Deliverables

- `prodbox.cabal` declares `tested-with: ghc ==9.12.4` at the package-stanza level
  per [dependency_management.md#toolchain-pinning](../documents/engineering/dependency_management.md#toolchain-pinning).
- `cabal.project` declares `with-compiler: ghc-9.12.4` per
  [dependency_management.md#toolchain-pinning](../documents/engineering/dependency_management.md#toolchain-pinning).
- The plan and [00-overview.md](00-overview.md) name the authoritative Cabal
  version `Cabal 3.16.1.0` per
  [dependency_management.md#toolchain-pinning](../documents/engineering/dependency_management.md#toolchain-pinning); the
  doctrine pins both the GHC and Cabal versions, and this sprint binds the Cabal
  pin in cabal-manifest terms alongside the existing GHC `9.12.4` references.
- `src/Prodbox/CheckCode.hs` gains a check that refuses any module-local
  definition in `app/prodbox/Main.hs` beyond a thin
  `main = Prodbox.App.main` (or equivalent library re-export) per
  [haskell_code_guide.md#project-structure](../documents/engineering/haskell_code_guide.md#project-structure)
  ("Most logic should live in `src/`, not `app/`, so it can be imported by tests
  and reused by other programs"). The check parses `app/prodbox/Main.hs`,
  rejects any top-level binding other than `main`, and refuses any local
  function or value definition inside `main` itself. A `library-first` lint
  message names the violation and points at the doctrine.
- Enqueue any pre-doctrine logic that currently lives in `app/prodbox/Main.hs`
  beyond the thin entrypoint in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending
  Removal` with Sprint 1.27 as the owning sprint. If `app/prodbox/Main.hs`
  already satisfies the thin-entrypoint contract on the current worktree, the
  sprint closes with no ledger row.

### Validation

1. `cabal build all` succeeds on the clean tree with the new
   `tested-with` / `with-compiler` declarations.
2. `prodbox check-code` fails when synthetic logic is added to
   `app/prodbox/Main.hs` beyond `main = Prodbox.App.main` and succeeds on the
   clean tree.
3. Doctrine identifiers `tested-with`, `with-compiler`, `Cabal 3.16.1.0`,
   `library-first`, and `thin Main.hs` each appear at least once in the plan
   suite after Sprint 1.27 lands.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/README.md` - Haskell-only doctrine index plus
  [the engineering doctrine docs](../documents/engineering/README.md) pointer.
- `documents/engineering/cli_command_surface.md` - canonical Haskell command matrix, deferring
  to the doctrine for `CommandSpec`, `Command Topology`, and `Progressive Introspection`;
  Sprint 1.29 adds the positional-args `CommandSpec` field and makes the §2/§3 operator matrix a
  registry-generated section.
- `documents/engineering/code_quality.md` - Haskell `check-code` contract, deferring to the
  doctrine for `Lint, Format, and Code-Quality Stack`, `Forbidden Surfaces`, and
  `Generated Artifacts`; Sprint 1.29 registers the generated §2/§3 matrix as a
  `GeneratedSectionRule`.
- `documents/engineering/haskell_code_guide.md` - hard-gate Haskell quality doctrine and
  review-guidance split, deferring to the doctrine for GADT state machines, smart
  constructors, subprocess values, retry policy, and capability classes; Sprint 1.30 rewrites
  the capability-classes / service-error sections to the argv-shaped reality (change D2):
  `runMinIO`/`runRedis`/`runPg :: [String] -> m (Either E ProcessOutput)`, `HasRedis` marked
  vestigial, constructor-classified `ServiceError`, and forbid-retry-of-non-retryable plus
  forbid-literal-`retryable`-`Bool` intents.
- `documents/engineering/dependency_management.md` - non-Python build and dependency posture,
  including the canonical Dockerfile location, `ghcup` toolchain pin, and no-symlink doctrine.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Envoy Gateway and Gateway API
  public-edge doctrine.
- `documents/engineering/effect_interpreter.md` - Haskell interpreter contract, deferring to
  the doctrine for `Subprocesses as Typed Values` and the Plan/Apply boundary.
- `documents/engineering/effectful_dag_architecture.md` - Haskell DAG model and layering.
- `documents/engineering/integration_fixture_doctrine.md` - integration setup and cleanup doctrine.
- `documents/engineering/local_registry_pipeline.md` - frontend-image location and Harbor-first
  registry expectations.
- `documents/engineering/prerequisite_dag_system.md` - prerequisite DAG construction and
  reduction; Sprint 1.31 documents the construction-time acyclicity invariant (back-edge →
  `Left AppError`).
- `documents/engineering/prerequisite_doctrine.md` - prerequisite registry doctrine, deferring
  to the doctrine for `Prerequisites as Typed Effects`; Sprint 1.31 records the
  `settings_loaded`/`settings_object` collapse and the interpreter satisfied-node memo.
- `documents/engineering/pure_fp_standards.md` - pure-FP and state-machine doctrine; Sprint 1.32
  softens the GADT-indexed-state-machine mandate (change D1) to permit a flat exhaustive ADT for
  externally-authoritative / log-reconciled state (the gateway `Disposition` projection) while
  keeping the exhaustive-ADT and no-raw-`String` requirements.
- `documents/engineering/distributed_gateway_architecture.md` - daemon-lifecycle parser shape;
  Sprint 1.29 binds the single `--config` knob on `prodbox gateway start`.
- `documents/engineering/config_doctrine.md` - host-CLI single-`--config` contract that
  Sprint 1.29 binds for the gateway/workload start parsers; Sprint 1.35 refines this contract
  so the typed Dhall config carries only `SecretRef` values, never plaintext secrets; Sprint 1.38
  inverts the SSoT so the in-force config is the Vault-Transit-enveloped MinIO object and the
  filesystem `prodbox-config.dhall` is a seed/propose input gated behind the unencrypted basics.
- `documents/engineering/vault_doctrine.md` - the fail-closed Vault secret-management SSoT for
  the typed `SecretRef` contract with no `FileSecret` arm (Sprint 1.35), the `prodbox vault`
  lifecycle surface plus the encrypted unlock bundle (Sprint 1.36), the sealed-Vault gate plus the
  production Vault-Transit `DekCipher` (Sprint 1.37), and the config SSoT inversion with
  root-token-gated config authority (Sprint 1.38). Vault is the sole
  secrets/KMS/PKI root; the master-seed HMAC-derivation model is retired (not extended) and Vault KV
  is the only secret store.
- `documents/engineering/cluster_federation_doctrine.md` - the root/child Vault transit-seal trust
  tree, parent custody of child init keys, downstream-cluster metadata as secret data, and the
  root-token config-write authority that Sprints 1.36/1.38 implement on the host-side surface.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - reconcile/teardown doctrine
  the Sprint 1.37 sealed-Vault Pulumi gate composes with (Vault readiness precedes every
  `prodbox aws stack ...` mutation).
- `documents/engineering/streaming_doctrine.md` - terminal streaming invariants.
- `documents/engineering/unit_testing_policy.md` - Haskell unit and integration harness
  doctrine, deferring to the doctrine for the tasty stack and stanza layout.

**Product docs to create/update:**

- `README.md` - supported operator flow after the Haskell rewrite.
- `AGENTS.md` - repository guidance for the Haskell architecture.
- `CLAUDE.md` - assistant guidance aligned to the rewritten repository.

**Cross-references to add:**

- Keep Phase `1` linked from [README.md](README.md) and [00-overview.md](00-overview.md).

## Sprint 1.28: `dhall` allow-newer Clauses and Env-Var-Read Lint Rule ✅

**Status**: Done (May 24, 2026 — existing `cabal.project allow-newer: *:base,
*:template-haskell` clause continues to satisfy the `dhall ^>=1.42` transitive
deps under GHC 9.12.4; `src/Prodbox/CheckCode.hs::checkEnvVarConfigReads` lint
rule landed and is wired into `runDoctrineAlignmentCheck`; the `PRODBOX_LOG_LEVEL` /
`PRODBOX_CONFIG_PATH` / `PRODBOX_PORT` env-var reads in `src/Prodbox/Gateway.hs`
are gone; daemon-lifecycle stanza tests updated to the new contract; 533/533
unit tests pass; `prodbox check-code` exit 0.)
**Blocked by**: Sprint 0.8 ([config_doctrine.md](../documents/engineering/config_doctrine.md)) — resolved
**Implementation**: `cabal.project` (`allow-newer` clauses), `prodbox.cabal` (no version bound
changes expected), `src/Prodbox/CheckCode.hs` (new `forbidEnvVarConfigReads` lint rule)
**Docs to update**: `documents/engineering/dependency_management.md`,
`documents/engineering/haskell_code_guide.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Make the `dhall ^>=1.42` library bound build cleanly under GHC `9.12.4` by extending the
existing `cabal.project` `allow-newer` clause set with whatever transitive deps `cabal
build` reports as version-bound-incompatible, and add the lint rule that enforces the
no-env-var-reads contract from
[config_doctrine.md §10](../documents/engineering/config_doctrine.md#10-forbidden-surfaces)
on supported config-loading paths.

### Deliverables

- Extend `cabal.project` `allow-newer` clause to cover whatever `dhall` transitive
  dependencies cabal complains about on GHC `9.12.4` (current clause is `allow-newer:
  *:base, *:template-haskell`; the implementing sprint will add named entries only after
  observing the specific cabal errors).
- New `src/Prodbox/CheckCode.hs::forbidEnvVarConfigReads` lint rule: refuses uses of
  `lookupEnv`, `getEnv`, `getEnvironment` from `System.Environment` in
  `src/Prodbox/Settings.hs`, `src/Prodbox/Gateway/Settings.hs`, `src/Prodbox/Gateway.hs`,
  `src/Prodbox/Workload.hs`, and any future config-loading module added to the registry.
  The rule strips string literals before token checks so doctrine references in comments
  don't false-positive.
- Migration note in `documents/engineering/dependency_management.md` listing the named
  `allow-newer` clauses and the conditions under which they may be removed (when an
  upstream `dhall` release bumps the bounds to match GHC `9.12.4`).
- Removal of the `PRODBOX_LOG_LEVEL` / `PRODBOX_CONFIG_PATH` / `PRODBOX_PORT` env-var
  reads in `src/Prodbox/Gateway.hs` (the matching ledger row sits in
  `legacy-tracking-for-deletion.md` and is owned by this sprint).

### Validation

1. `prodbox check-code` exit 0 (proves the new lint rule fires only on intentional
   violations, not on legitimate non-config env-var reads in test helpers).
2. `prodbox test unit` exit 0 (no test text changes expected).
3. `prodbox build` succeeds cleanly under GHC `9.12.4` with the extended `allow-newer`
   set (currently it already does; this sprint is preemptive).

### Remaining Work

- The implementing sprint discovers the exact `allow-newer` set by running `cabal build`
  against the current `cabal.project` and reading the errors. Until that build is run, the
  `allow-newer` set listed in Deliverables is a placeholder.

## Sprint 1.29: CommandSpec Positional Args and Generated Operator Matrix ✅

**Status**: Done (2026-06-09). Added the `ArgumentSpec` positional-args field to `CommandSpec` and
generated the `cli_command_surface.md` §2/§3 operator command matrix from `commandRegistry` as two
marker-delimited `GeneratedSectionRule`s (`command-surface-toplevel`, `command-surface-matrix`), so
the matrix can no longer drift from the typed registry; the previously-omitted live commands
(`users invite|list|revoke`, `host firewall gateway-unrestrict`, `pulumi aws-ses-migrate-backend`,
`test integration keycloak-invite`) now render automatically. The one-knob daemon/workload parser
reduction is **not** part of this sprint — it is the override-flag/`PRODBOX_*` removal owned by
Sprints `2.24` (daemon) and `3.15` (workload); 1.29 generates the *current* parser surface.
Validation green: `check-code` 0, `test unit` 742, `docs generate` → `docs check` 0, `lint docs` 0.
**Implementation**: `src/Prodbox/CLI/Spec.hs` (`ArgumentSpec` + `arguments` field +
`leafWithArgs`/`argument`/`repeatableArgument`), `src/Prodbox/CLI/Docs.hs`
(`renderCommandSurfaceTopLevel`, `renderCommandSurfaceMatrix`), `src/Prodbox/CheckCode.hs` (the two
registered `GeneratedSectionRule`s), `documents/engineering/cli_command_surface.md` (markers +
populated content), `test/unit/Main.hs` (10 cases)
**Docs to update**: `documents/engineering/cli_command_surface.md` (done)

### Objective

Make `commandRegistry` the single typed source for the operator command matrix and reduce the
daemon-launching parsers to the doctrine's one-knob shape, per
[cli_command_surface.md#command-topology](../documents/engineering/cli_command_surface.md#command-topology),
[code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts),
and [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
This sprint supplies the positional-args `CommandSpec` field that Sprint `0.10` consumes to
generate the §2/§3 matrix from a typed registry rather than a hand-maintained table.

### Deliverables

- Add a positional-args field to `CommandSpec` (alongside the Sprint 1.6 `name`, `summary`,
  `description`, `children`, `options`, `examples` fields) so every command's positional
  arguments are declared in the typed registry, not only its flags, per
  [cli_command_surface.md#command-topology](../documents/engineering/cli_command_surface.md#command-topology).
  The field is the documentation SSoT consumed by the generated matrix; the `optparse-applicative`
  parser keeps parsing positionals via its existing `argument` combinators (unifying the two is an
  optional future refinement, not required for the matrix-generation goal, and the field is purely
  additive so there is no positional-args residue to remove).
- Generate the [cli_command_surface.md](../documents/engineering/cli_command_surface.md) §2/§3
  operator command matrix from `commandRegistry` as a marker-delimited generated section via
  `GeneratedSectionRule` (Sprint 1.10), so the matrix cannot drift from the registry. This is
  the typed source Sprint `0.10` builds on; `prodbox docs check` fails on drift.
- (Deferred — not this sprint.) Reducing `prodbox gateway start` / `prodbox workload start` to a
  single `--config <path>` knob IS the override-flag/`PRODBOX_*` removal, owned by Sprint `2.24`
  (daemon) and Sprint `3.15` (workload). 1.29 generates the *current* parser surface, so the matrix
  reflects those flags until 2.24/3.15 remove them and the matrix regenerates.
- Enqueue the pre-doctrine positional-args-outside-`CommandSpec` residue in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with Sprint 1.29 as the
  owning sprint.

### Validation

1. `prodbox docs check` is a no-op on a clean tree after the §2/§3 matrix is generated from
   `commandRegistry`; hand-editing the matrix fails `prodbox lint files`.
2. A `prodbox-unit` parser test (Sprint 1.25) asserts that every command's declared positional
   args round-trip through `execParserPure` to the typed `Command` value.
3. `prodbox gateway start --config <path>` and `prodbox workload start --config <path>` accept
   only the single `--config` knob; the golden `--help` output (Sprint 1.6) reflects the
   one-knob shape.

### Remaining Work

None — closed 2026-06-09. The positional-args field and the generated §2/§3 matrix landed and
round-trip green (`docs generate` → `docs check` 0). The one-knob parser reduction was never in
this sprint's scope; it is owned by Sprints `2.24`/`3.15`.

## Sprint 1.30: Classifiable ServiceError and Argv-Shaped Capability Doctrine ✅

**Status**: Done (2026-06-09). `ServiceError` is now a constructor sum
(`SEConnectionFailed`/`SETimeout`/`SEConflict`/`SEInternalError` retryable;
`SENotFound`/`SEPermissionDenied` not) with retryability DERIVED via the total
`serviceErrorRetryable` plus a single `classifyServiceError` boundary in
`runServiceSubprocessWithEnv`; `checkServiceErrorRetryableLiteral` fails check-code on any hand-set
literal. The retrier and the new `pollUntilReady` readiness-poller are separate combinators (the
ChartPlatform Patroni waits and the daemon-lifecycle HTTP wait were migrated to the poller). One
`awsCliSubprocessEnvironment` (PATH/HOME/LANG-preserving) is the sole AWS-CLI env builder;
`adminAwsEnvironment` delegates to it and the `Dns.hs` Route 53 subprocesses route through it,
fixing the bare-`aws` PATH-drop. Dead `Retry.retryAppError`/`defaultRetryPolicy` removed (ledger
row → Completed). The D2 doctrine rewrite landed in Sprint 0.9. Validation green: `check-code` 0,
`test unit` 750, `lint docs` 0, `docs check` 0.
**Implementation**: `src/Prodbox/Service.hs`, `src/Prodbox/Retry.hs`,
`src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/Dns.hs`, `src/Prodbox/EffectInterpreter.hs`,
`src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`
(recommended)
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Make `serviceErrorRetryable` a real, constructor-derived classification and align the
capability/error doctrine (change D2) with the argv-shaped reality, per
[haskell_code_guide.md#capability-classes-and-service-errors](../documents/engineering/haskell_code_guide.md#capability-classes-and-service-errors)
and [haskell_code_guide.md#retry-policy-as-first-class-values](../documents/engineering/haskell_code_guide.md#retry-policy-as-first-class-values).

### Deliverables

- Replace the hand-built `retryable :: Bool` field on `ServiceError` with a classifiable
  `ServiceError` sum classified at the single subprocess boundary, so `serviceErrorRetryable`
  is derived from the constructor rather than carried as a literal. Forbid hand-built
  `ServiceError` values that pin a literal `retryable` `Bool`, via a `prodbox check-code`
  lint rule, per
  [haskell_code_guide.md#capability-classes-and-service-errors](../documents/engineering/haskell_code_guide.md#capability-classes-and-service-errors).
- Split the retrier (retries a classified-retryable action with backoff) from the
  readiness-poller (polls a steady-state predicate until ready or timeout); the two are
  distinct concerns and must not share one loop, per
  [haskell_code_guide.md#retry-policy-as-first-class-values](../documents/engineering/haskell_code_guide.md#retry-policy-as-first-class-values).
- Introduce one PATH/HOME-preserving `awsCliSubprocessEnvironment` builder consumed by every
  `aws`-invoking path, and fix the `src/Prodbox/Dns.hs` bare-`aws` invocation that currently
  drops `PATH` (so the `aws` binary is not found on the supported path). All `aws` subprocess
  environments route through the one builder.
- Delete the dead `src/Prodbox/Retry.hs` exports with no remaining call sites; enqueue the
  removed exports in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with
  Sprint 1.30 as the owning sprint.
- Doctrine change D2: rewrite the
  [haskell_code_guide.md](../documents/engineering/haskell_code_guide.md) capability-classes
  section to the argv-shaped reality — `runMinIO` / `runRedis` / `runPg ::
  [String] -> m (Either E ProcessOutput)` — and mark `HasRedis` vestigial (zero `src/`
  callers). Keep the typed-`ServiceError`-classified-by-constructor and
  forbid-retry-of-non-retryable intents as the target the code moves to; the D2 doc rewrite
  is landable in the Sprint `0.9` docs-only pass ahead of the code.

### Validation

1. A `prodbox-unit` test asserts `serviceErrorRetryable` is derived from the `ServiceError`
   constructor and that a retryable error retries while a non-retryable error does not.
2. `prodbox check-code` fails when a `ServiceError` is constructed with a literal `retryable`
   `Bool` or when an `aws` subprocess is built without `awsCliSubprocessEnvironment`.
3. `prodbox dns check` (and any `aws`-invoking path) finds the `aws` binary on the supported
   path with the PATH/HOME-preserving environment.

### Remaining Work

None — closed 2026-06-09. All deliverables landed (the D2 doctrine doc was rewritten in Sprint
0.9; this sprint converged the code to it). The capability classes were intentionally left
argv-shaped per D2 (the reality); only the error classification changed.

## Sprint 1.31: Prerequisite-DAG Acyclicity at Construction and Interpreter Memo ✅

**Status**: Done (2026-06-09). `transitiveClosureIds` now carries a DFS recursion-stack and rejects
a back-edge with `Left` (naming the cycle path) in the same pure `Either String` expansion that
already rejects missing ids — acyclicity is a construction-time invariant, not a traversal-time
tolerance (`fromRootIds` inherits it). The structured error stays `Either String` because
[prerequisite_dag_system.md](../documents/engineering/prerequisite_dag_system.md) §3 specifies that
expansion path and every caller already handles `Left`. The duplicate `settings_loaded` node was
collapsed into `settings_object` (the `aws_credentials_valid` edge re-pointed; ledger row added). A
boundary-only `SatisfiedEffectMemo` threaded through `runEffectDAG` evaluates each satisfied
prerequisite at most once per run. Validation green: `check-code` 0, `test unit` 757, `lint docs` 0,
`docs check` 0, `integration cli` 35/35.
**Implementation**: `src/Prodbox/Prerequisite.hs`, `src/Prodbox/EffectDAG.hs`,
`src/Prodbox/EffectInterpreter.hs`, `test/unit/Main.hs` (recommended)
**Docs to update**: `documents/engineering/prerequisite_doctrine.md`,
`documents/engineering/prerequisite_dag_system.md`

### Objective

Enforce prerequisite-DAG acyclicity at construction time and collapse the redundant
settings-node pair, per
[prerequisite_doctrine.md#prerequisites-as-typed-effects](../documents/engineering/prerequisite_doctrine.md#prerequisites-as-typed-effects)
and the DAG-construction discipline in
[prerequisite_dag_system.md](../documents/engineering/prerequisite_dag_system.md).

### Deliverables

- Reject back-edges at DAG construction: the DAG constructor returns `Left` (the doctrine's
  `Either String` expansion path) rather than tolerating the cycle at traversal time when a node
  introduces a back-edge, so an acyclic DAG is a construction-time invariant, per
  [prerequisite_dag_system.md](../documents/engineering/prerequisite_dag_system.md).
- Collapse the `settings_loaded` / `settings_object` prerequisite nodes into one node; the two
  currently model the same satisfied condition and the split adds no information. Enqueue the
  removed node in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with
  Sprint 1.31 as the owning sprint.
- Add an interpreter satisfied-node memo so an already-satisfied prerequisite is not
  re-evaluated within one interpreter run, per
  [prerequisite_doctrine.md#prerequisites-as-typed-effects](../documents/engineering/prerequisite_doctrine.md#prerequisites-as-typed-effects).

### Validation

1. A `prodbox-unit` test asserts that constructing a registry with a back-edge returns
   `Left` and names the offending node.
2. A `prodbox-unit` test asserts the single collapsed settings node satisfies every path that
   previously expanded both `settings_loaded` and `settings_object`.
3. A `prodbox-unit` test asserts the interpreter evaluates a satisfied prerequisite once per
   run (the memo prevents re-evaluation).

### Remaining Work

None — closed 2026-06-09. Construction-time acyclicity, the settings-node collapse, and the
interpreter memo all landed and are unit- and integration-covered.

## Sprint 1.32: Retire StateMachine.hs and Realign the GADT Doctrine ✅

**Status**: Done (2026-06-09). `src/Prodbox/StateMachine.hs` (un-adopted — zero `src`/`app`
importers; its `Some*` existentials lacked singleton witnesses) was deleted along with its lone
typecheck test in `test/unit/Main.hs` and its `prodbox.cabal` `exposed-modules` entry; the ledger
row moved to Completed. The D1 GADT-doctrine softening already landed in `pure_fp_standards.md`
(Sprint 0.9) and was verified consistent (a flat exhaustive ADT is permitted for
externally-authoritative / log-reconciled state; raw-`String` state and missing-singleton
existentials remain forbidden). Validation green: `check-code` 0, `test unit` 756, `lint docs` 0,
`docs check` 0, `cabal build all` 0.
**Implementation**: `src/Prodbox/StateMachine.hs` (removal),
`test/unit/Main.hs` (typecheck-test removal), `prodbox.cabal`,
`src/Prodbox/CheckCode.hs` (recommended)
**Docs to update**: `documents/engineering/pure_fp_standards.md`

### Objective

Retire the un-adopted `src/Prodbox/StateMachine.hs` and its lone typecheck test, and realign
the GADT-indexed-state-machine doctrine (change D1) to the externally-authoritative,
log-reconciled state the gateway actually uses, per
[pure_fp_standards.md#gadt-indexed-state-machines](../documents/engineering/pure_fp_standards.md#gadt-indexed-state-machines).

### Deliverables

- Delete `src/Prodbox/StateMachine.hs` (no supported call site adopts it) and its single
  typecheck test in `test/unit/Main.hs`; drop the module from `prodbox.cabal`. Enqueue the
  removal in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with Sprint
  1.32 as the owning sprint.
- Doctrine change D1: soften the
  [pure_fp_standards.md#gadt-indexed-state-machines](../documents/engineering/pure_fp_standards.md#gadt-indexed-state-machines)
  mandate to "GADTs for authoritative in-process transitions; externally-authoritative /
  log-reconciled state (e.g. gateway ownership as a fold over the append-only commit log — a
  `Disposition` projection) may use a flat exhaustive ADT." Keep the exhaustive-ADT and
  no-raw-`String` requirements, and keep the matching Forbidden-list entry consistent with the
  softened mandate. The D1 doc rewrite is landable in the Sprint `0.9` docs-only pass ahead of
  the code removal.

### Validation

1. `cabal build all` and `prodbox check-code` succeed after `src/Prodbox/StateMachine.hs` and
   its typecheck test are removed.
2. `documents/engineering/pure_fp_standards.md` permits a flat exhaustive ADT for
   externally-authoritative log-reconciled state while still forbidding raw-`String` state and
   requiring exhaustive matching.
3. No supported-path module imports `Prodbox.StateMachine` after the removal.

### Remaining Work

None — closed 2026-06-09. Module, test, and cabal entry removed; the D1 doctrine softening
(Sprint 0.9) was verified consistent. No supported-path module imports `Prodbox.StateMachine`.

## Sprint 1.35: Typed SecretRef Config Contract ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/Settings/SecretRef.hs` (FileSecret-free union + `FromDhall` decoder + production plaintext validator + Vault KV resolver seam)
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/vault_doctrine.md`

**Current state (2026-06-15)**: the **`SecretRef` type (now `FileSecret`-free), its `FromDhall`
decoder, the production-plaintext validator, the resolver's local arm, and the Vault KV resolver
seam** have **landed and
validated**. `Prodbox.Settings.SecretRef.SecretRef` is the typed reference with exactly
`SecretRefVault` / `SecretRefTransitKey` / `SecretRefPrompt` / `SecretRefTestPlaintext` — the
`SecretRefFile` constructor and its disk-reading resolver arm (and the `SecretRefFileReadFailed`
error) are **deleted**, so the union has no `FileSecret` arm (vault_doctrine §3: Secret-mounted
plaintext Dhall fragments are removed, not bridged). A `FromDhall SecretRef` instance decodes the
`< Vault | TransitKey | Prompt | TestPlaintext >` Dhall union; `secretRefIsPlaintext` +
`validateProductionSecretRef` reject a plaintext literal on a production path; `resolveSecretRef`
resolves `TestPlaintext` only in `TestHarnessMode` and its compatibility path still fails loud
(`SecretRefVaultUnavailable`) for `Vault` / `TransitKey` unless a Vault reader is explicitly
supplied. `resolveSecretRefWithVault` and `resolveSecretRefFromVault` now consume
`vaultKvReadV2` from Sprint `1.36` so `SecretRef.Vault` can resolve through Vault KV when the
caller has a token. Unit tests cover the plaintext flag, the production accept/reject, the resolver
modes, injected Vault-reader resolution, and the Dhall decode of a `SecretRef.Vault` /
`SecretRef.TestPlaintext` literal. Gates green: `./.build/prodbox dev check` 0,
`./.build/prodbox dev docs check` 0, `./.build/prodbox dev lint docs` 0, and
`./.build/prodbox test unit` **909/909**. **Closure update (2026-06-16)**: Phase `1` owns the
typed reference contract and resolver seam. The runtime migrations of AWS provider credentials and
ACME EAB material are deliberately owned by Sprints `7.14` and `7.15`, where the Pulumi
decrypt-to-scratch path and public-edge TLS authority move those secret values behind Vault end to
end.

### Objective

Provide the typed reference contract that every sensitive configuration field uses as it migrates
behind Vault, so `SecretRef` is the only supported config secret-reference surface
(vault_doctrine §3–§4). The `SecretRef` union carries no `FileSecret` arm:
Secret-mounted plaintext Dhall fragments are removed, not bridged, and in-cluster consumers
authenticate to Vault directly via Vault Kubernetes auth.

### Deliverables

- A shared `SecretRef` Dhall union (`Vault | TransitKey | Prompt | TestPlaintext`, with **no**
  `FileSecret` arm) in `prodbox-config-types.dhall` and a matching `Prodbox.Settings.SecretRef` ADT.
  `Vault`/`TransitKey` are the production targets; `Prompt` is CLI-only one-off elevated material;
  `TestPlaintext` is accepted only by the test harness from `test-config.dhall`.
- The landed `SecretRefFile` constructor and its disk resolver arm are deleted from
  `Prodbox.Settings.SecretRef` (queued in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).
- `validateProductionSecretRef` rejects `TestPlaintext` outside the test harness, and the resolver
  returns `SecretRefVaultUnavailable` unless a Vault reader is explicitly supplied.
- `resolveSecretRefWithVault` / `resolveSecretRefFromVault` resolve `SecretRef.Vault` through
  Vault KV v2 once a caller has a Vault address and token.

### Validation

- Unit tests: production mode rejects `TestPlaintext`, test-harness mode accepts it, and injected
  Vault-reader resolution returns the requested field.
- The `SecretRef` union has no `FileSecret`/`SecretRefFile` arm; SecretRef golden tests (Sprint
  `5.8`) assert the `FileSecret`-free shape.

### Remaining Work

None for Sprint `1.35`. Runtime field migrations that consume this contract are owned by Sprint
`7.14` (AWS provider credentials), Sprint `7.15` (ACME EAB / TLS key material), and Sprint `8.9`
(invite-flow SMTP/OIDC secrets).

## Sprint 1.36: `prodbox vault` Command Group and Encrypted Unlock Bundle ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/Vault/UnlockBundle.hs`, `src/Prodbox/Vault/Client.hs` (authenticated KV/Transit/seal/reconcile/rotate/PKI surface), `src/Prodbox/Http/Client.hs` (header-bearing helpers + no-response JSON POST), `src/Prodbox/Vault/Orchestration.hs` (pure unseal plan), `src/Prodbox/Vault/Reconcile.hs` (base mount/auth/policy/Transit/Kubernetes-role reconcile plan), `src/Prodbox/CLI/Vault.hs` (init/unseal/seal/reconcile/rotate/PKI orchestration + operator-password seam), `test/integration/CliSuite.hs` (native CLI lifecycle proof)
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/cluster_federation_doctrine.md`

**Current state (2026-06-12)**: the encrypted **unlock bundle** deliverable has **landed and
validated**. `Prodbox.Vault.UnlockBundle` derives a key from the operator password via **Argon2id**
(crypton; iterations 3 / 64 MiB / parallelism 1, params stored in the envelope) and seals the
bundle JSON with **ChaCha20-Poly1305** AEAD into a self-describing `prodbox-vault-unlock-bundle-v1`
envelope; the derived key is held in `ScrubbedBytes`. Four unit tests cover the encrypt/decrypt
round-trip, wrong-password AEAD rejection (`UnlockBundleAuthFailed`), tamper rejection, and the
no-plaintext-leak property.

The **Vault HTTP client** has also landed and validated. `Prodbox.Vault.Client` speaks the
unauthenticated `sys/seal-status`, `sys/init`, and `sys/unseal` endpoints of Vault's HTTP API
through the native `Prodbox.Http.Client` (no curl), with a pure `bootstrapAction`
(initialize / unseal / ready decision) and `initResponseToUnlockBundle` (capturing the init keys +
root token into the unlock bundle). Five unit tests cover the three `bootstrapAction` decisions, the
seal-status decode, and the init-response → unlock-bundle mapping.

The **`prodbox vault` command group** is now wired end-to-end:
`vault status|init|unseal|seal|reconcile|rotate-unlock-bundle|rotate-transit-key|pki status|pki
issue-test-cert` parse through the registry (`Command` / `Spec` / `Parser` / `Native`), with
`Prodbox.CLI.Vault.runVaultCommand` handling them — `vault status` probes the in-cluster Vault and
reports initialized / sealed / unseal-progress (or unreachable); the mutating subcommands now use
the native Vault HTTP client, the encrypted unlock bundle, and readiness checks. The man pages, shell
completions, and the generated command-registry / command-surface-matrix tables were regenerated,
and four CLI parser/golden checks (routing, `commands-tree`, `commands.json`, `help-all`) cover it.

Gates green: `dev check` 0 (Fourmolu/HLint/warning-clean + generated-artifact lint), `dev docs
check` 0, `dev lint docs` 0, `test unit` **854/854**. `crypton ^>=1.0.6` + `memory ^>=0.18` added to
the library deps.

**Update (2026-06-14)**: the **authenticated (token-bearing) client surface** has **landed and
validated**. `Prodbox.Http.Client` gains header-bearing request helpers (`httpGetJsonWithHeaders`,
`httpPostJsonWithHeaders`, `httpRequestNoBody` over a shared `sendRequestRaw` engine), and
`Prodbox.Vault.Client` gains a `VaultToken` (`X-Vault-Token`) plus `vaultSeal` (`PUT sys/seal`),
`vaultKvReadV2` / `vaultKvWriteV2` (the KV v2 `data.data` envelope), and `vaultTransitEncrypt` /
`vaultTransitDecrypt` (Transit wrap/unwrap with base64 plaintext). Four offline wire-format unit
tests pin the KV-write/read and Transit-encrypt request/response JSON. Gates green: `dev check` 0,
`dev docs check` 0, `test unit` **873/873**. This is the surface `SecretRef.Vault` resolution and
the Transit-backed envelope `DekCipher` (both Sprint `3.17`) consume.

**Update (2026-06-14, orchestration)**: the **`vault init` / `unseal` / `seal` orchestration** has
**landed and validated**. A new pure `Prodbox.Vault.Orchestration` module holds the total,
unit-tested decision logic (`planUnseal` over a `SealStatus` + key shares, `interpretUnsealProgress`
per-submission classification, the canonical `.data/prodbox/vault-unlock-bundle.age` path);
`Prodbox.CLI.Vault` wires `vault init` (probe → `bootstrapAction` guard so it inits **exactly once**
and is an idempotent no-op on an already-initialized Vault → `vaultInit` → `initResponseToUnlockBundle`
→ `encryptUnlockBundle` → write the `.age` bundle), `vault unseal` (read+decrypt the bundle →
`planUnseal` → submit shares until unsealed, aborting on a stalled share), and `vault seal` (root
token from the decrypted bundle → `vaultSeal`). The operator-password seam reads `test-config.dhall`
when present and otherwise prompts on a TTY with echo disabled; keys / token / password are never
logged. The host address is corrected to the chart NodePort `http://127.0.0.1:31820`. Eight pure
orchestration unit tests added. Gates green: `dev check` 0, `dev docs check` 0, `test unit`
**881/881**.

**Update (2026-06-15, reconcile foundation)**: the base **`vault reconcile`** path has landed and
validated offline. `Prodbox.Vault.Client` now covers the Vault sys/mounts, sys/auth, ACL-policy,
Transit-key read/create, and Kubernetes-auth role write endpoints, with `httpPostJsonNoResponse`
handling Vault's common 204 responses. `Prodbox.Vault.Reconcile` owns the idempotent ordered plan:
enable `secret/` as KV v2, `transit/`, and `pki/`; enable Kubernetes auth; ensure the per-domain
Transit keys (`prodbox-active-config`, `prodbox-gateway-state`, `prodbox-pulumi-state`,
`prodbox-minio-envelope`, `prodbox-downstream-cluster-config`); rewrite the baseline gateway,
Pulumi, and federation-custody policies; and rewrite the planned Kubernetes auth roles. Existing
mount/auth/key drift fails loud when the type or required KV option is wrong. `Prodbox.CLI.Vault`
wires `vault reconcile`: it refuses uninitialized or sealed Vaults before authenticated work,
decrypts the unlock bundle, uses the captured root token, applies `defaultVaultReconcilePlan`, and
prints a per-step report. Nine unit tests cover the new request JSON, default plan shape, creation
order, and wrong-mount-type refusal. Validation in this increment: `cabal build --builddir=.build
exe:prodbox test:prodbox-unit` 0, `cabal test --builddir=.build prodbox-unit
--test-options='--hide-successes'` **915/915**, `./.build/prodbox test unit` **915/915**,
`./.build/prodbox dev check` 0, `./.build/prodbox dev docs check` 0, and `./.build/prodbox dev lint
docs` 0.

**Update (2026-06-15, remaining Vault leaves)**: the rest of the `prodbox vault` leaf handlers are
now wired. `vault rotate-unlock-bundle` decrypts the existing host unlock bundle, obtains and
confirms a new hidden password on a TTY (or reuses the test-only `test-config.dhall` password for
automation), and writes a freshly encrypted bundle without touching Vault state. `vault
rotate-transit-key KEY` requires initialized+unsealed Vault, recovers the root token from the
unlock bundle, and calls Vault Transit key rotation. `vault pki status` verifies the baseline `pki`
mount, and `vault pki issue-test-cert` calls `pki/issue/prodbox-test` for a one-minute test
certificate; that final command is expected to fail with an actionable Vault HTTP error until
Sprint `7.15` installs the concrete issuer/role. One new unit test covers the PKI issue request and
response JSON; gates: `cabal build --builddir=.build exe:prodbox test:prodbox-unit` 0, `cabal test
--builddir=.build prodbox-unit --test-options='--hide-successes'` **916/916**, and
`./.build/prodbox test unit` **916/916**, `./.build/prodbox dev check` 0,
`./.build/prodbox dev docs check` 0, and `./.build/prodbox dev lint docs` 0.

**Closure update (2026-06-16)**: the native CLI lifecycle proof now exercises the full root-Vault
command path against a Vault-compatible loopback server through the built `prodbox` executable:
`vault status`, `vault init`, idempotent re-`init`, `vault unseal` using `test-config.dhall`,
`vault reconcile`, `vault rotate-unlock-bundle`, `vault rotate-transit-key prodbox-minio-envelope`,
`vault pki status`, `vault pki issue-test-cert`, and `vault seal`. The proof verifies that init
creates `.data/prodbox/vault-unlock-bundle.age`, re-init refuses to regenerate state, reconcile
writes the baseline policy / role / secret-object plan, the PKI test command decodes a Vault PKI
response, and the final Vault state is initialized and sealed. Targeted validation:
`cabal test --builddir=.build test:prodbox-integration --test-options='-p "Sprint 1.36"'` passed.
Full post-closure validation: `./.build/prodbox test unit` 908/908,
`./.build/prodbox test integration cli` 36/36, `./.build/prodbox dev docs check`,
`./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and
`./.build/prodbox dev check`.

### Objective

Add the host-side root Vault lifecycle surface — status, init, unseal, reconcile, seal, key
rotation, and PKI inspection — plus the encrypted unlock bundle that lets a
torn-down-and-recreated root/local cluster recover its Vault (vault_doctrine §6–§7). The
child-cluster transit-seal model and custody payload shape are implemented by Sprint `3.20`, while
direct live child registration and federated auto-unseal are closed by Sprint `4.32`; the
gateway-mediated child bootstrap surface is closed by Sprint `2.26`.

### Deliverables

- The `prodbox vault status|init|unseal|seal|reconcile|rotate-unlock-bundle|rotate-transit-key|pki status|pki issue-test-cert` command group.
- `vault init` is idempotent (init-if-empty) and runs **exactly once, ever** against an empty Vault
  PV; it captures unseal/recovery keys + the initial root token exactly once and writes them only to
  the encrypted unlock bundle. Every subsequent reconcile **unseals** existing data — no re-init, no
  key regeneration.
- The root cluster's unlock bundle at `.data/prodbox/vault-unlock-bundle.age` uses an Argon2id (or
  scrypt) KDF + age/sops-style authenticated encryption — never raw SHA-256. The unlock-bundle
  password unseals the root Vault and is stored nowhere persistent (the test harness simulates it
  through `test-config.dhall`).
- `vault unseal` reads the bundle, prompts for the password (or takes it from the test harness),
  decrypts in memory, and unseals; plaintext keys are never persisted.
- `vault reconcile` idempotently reconciles auth mounts, policies, roles, KV mounts, Transit keys
  (including per-domain Transit keys and the child-cluster seal key), PKI mounts/issuers, and
  Kubernetes auth roles.

### Validation

- Vault init creates an encrypted unlock bundle; re-running init against existing state is a no-op
  (init-once/unseal-on-rebuild).
- Vault unseal succeeds using a password from `test-config.dhall`.
- Vault reconcile creates KV, Transit, PKI, policies, and Kubernetes auth roles.
- Vault rotate, PKI status, PKI issue-test-cert, and seal run through the native CLI against a
  Vault-compatible HTTP surface.

### Remaining Work

- None for Sprint `1.36`. Root/local lifecycle integration into `prodbox cluster reconcile` closed
  under Sprint `4.29`; the root Shamir + child transit-seal hierarchy closed under Sprint `3.20`;
  direct live child registration and the federated unseal cascade closed under Sprint `4.32`; the
  gateway-mediated federation bootstrap closed under Sprint `2.26`; the concrete PKI issuer/role setup
  remains under Sprint `7.15`.

## Sprint 1.37: Sealed-Vault Gate and Production Vault-Transit DekCipher ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/Vault/Gate.hs`, `src/Prodbox/Vault/TransitCipher.hs`, `src/Prodbox/CLI/Pulumi.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/lifecycle_reconciliation_doctrine.md`

**Current state (2026-06-12)**: the **sealed-Vault gate decision** has **landed and validated**.
`Prodbox.Vault.Gate.vaultGateDecision` folds a `vaultSealStatus` probe (or its failure) into a
typed verdict — `VaultGateAllow` only when Vault is initialized and unsealed; otherwise
`VaultGateBlockSealed` / `VaultGateBlockUninitialized` / `VaultGateBlockUnreachable` — and
`renderVaultGateBlock` emits the fail-closed operator message ("Blocked: Vault is sealed. … No
preview/update/destroy was started. Run: prodbox vault unseal") per
[vault_doctrine.md §10](../documents/engineering/vault_doctrine.md#10-pulumi-backend-under-vault).
Four unit tests cover the allow / sealed / uninitialized decisions and the fail-closed message.
Gates green at that checkpoint: `dev check` 0, `test unit` **858/858**. The later updates below
activate the apply-path wiring and close the sealed-Vault refusal proof.

**Update (2026-06-14, superseded by the 2026-06-15 wiring below)**: the **decision→action fold** has landed and validated.
`vaultGateOutcome :: Either HttpError SealStatus -> VaultGateOutcome` (in `Prodbox.Vault.Gate`) is the
total, unit-testable seam the apply-path wiring consults — `VaultGateProceed` iff the gate allows,
otherwise `VaultGateRefuse <rendered message>` carrying the fail-closed stderr text. Four unit tests
cover proceed / sealed / uninitialized / unreachable. Gates green: `dev check` 0, `dev docs check` 0,
`test unit` **885/885**.

**Reframe (2026-06-15)**: this sprint drops "Vault-Derived Secrets Provider." Under **Model B**
(prodbox application-level Vault-Transit envelope per object, finalized in
[vault_doctrine.md §9/§10](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store)),
**Pulumi's own secrets provider is dropped** — the prodbox envelope *is* the encryption, so there is
no Pulumi passphrase to derive from Vault. The retired Vault-derived Pulumi-passphrase / Option-B
deliverable is recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
(owning Sprint `7.14`). What this sprint now owns instead is the **shared cryptographic dependency
every envelope needs**: the production Vault-Transit `DekCipher` (`Prodbox.Vault.TransitCipher`)
binding `dekWrap = vaultTransitEncrypt` / `dekUnwrap = vaultTransitDecrypt`
(`src/Prodbox/Vault/Client.hs`). A sealed Vault makes both fail, so every consumer — the in-force
config (Sprint `1.38`), the Model-B object-store (Sprint `4.30`), and the decrypt-to-scratch Pulumi
interposition (Sprint `7.14`) — seals/opens fail-closed by construction.

**Update (2026-06-15)**: the **production Vault-Transit `DekCipher`** has **landed and validated**.
`Prodbox.Vault.TransitCipher.vaultTransitDekCipher` delegates `dekWrap` to
`vaultTransitEncrypt` and `dekUnwrap` to `vaultTransitDecrypt`, mapping Vault HTTP/decode failures
into envelope wrap/unwrap failures so sealed or unreachable Vault paths fail closed. The
`vaultTransitDekCipherWith` seam lets unit tests exercise delegation without a live Vault. Gates
green: `./.build/prodbox dev check` 0, `./.build/prodbox dev docs check` 0,
`./.build/prodbox dev lint docs` 0, and `./.build/prodbox test unit` **909/909**.

**Update (2026-06-15 later)**: the **Pulumi apply-path sealed-Vault gate** has **landed and
validated**. `runPulumiCommand` now routes through `runPulumiCommandWithGate`, which probes
`vaultSealStatus` at the host Vault address (`http://127.0.0.1:31820`) only when
`runPlanWithOptions` executes a real stack action. A dry-run remains plan-only and does not probe
Vault; a blocked real apply/destroy/migrate path prints the redacted `VaultGateRefuse` message and
returns `ExitFailure 1` before any stack action starts. Unit coverage pins both paths. Gates green:
`cabal test --builddir=.build prodbox-unit --test-options='--hide-successes'` **918/918**.

**Update (2026-06-16)**: the sealed-Vault refusal proof is covered by a native CLI integration test
that runs `prodbox aws stack eks reconcile` against the real command parser/dispatch path while the
Pulumi gate probes a loopback Vault-compatible `sys/seal-status` endpoint reporting
`initialized=true, sealed=true`. The command exits `1`, prints the redacted sealed-Vault refusal
(`Blocked: Vault is sealed. ... Run: prodbox vault unseal`), and the fake Pulumi record file is
absent, proving no stack action started.

### Objective

Land the two shared Vault dependencies every later envelope sprint composes on: (1) the
fail-closed sealed-Vault gate that makes every `prodbox aws stack ...` operation refuse to run while
Vault is sealed, before any AWS-side mutation is attempted (vault_doctrine §10); and (2) the
production Vault-Transit `DekCipher` (`Prodbox.Vault.TransitCipher`) that the in-force config,
the Model-B object-store, and the Pulumi interposition all wrap. The gate is mandatory and
fail-closed: a sealed, unreachable, or uninitialized Vault blocks preview, update, and destroy
alike with no degraded path that touches state. There is **no** Pulumi secrets provider to derive
keys for — Model B's envelope is the encryption (Sprint `7.14`).

### Deliverables

- A Vault readiness check that precedes every real Pulumi apply/destroy/migrate stack action and
  gates it before AWS-side mutation. Sprint `1.37` lands the reachable / initialized / unsealed
  seal-status gate (`vaultGateDecision` / `vaultGateOutcome` plus `runPulumiCommandWithGate`);
  Sprint `7.14` adds the backend-decryptability check when the decrypt-to-scratch backend
  interposition exists.
- The production Vault-Transit `DekCipher` (`Prodbox.Vault.TransitCipher`) binding
  `dekWrap = vaultTransitEncrypt` / `dekUnwrap = vaultTransitDecrypt`
  (`src/Prodbox/Vault/Client.hs`), obtainable only when Vault is unsealed and reused by every
  envelope consumer (Sprints `1.38` / `4.30` / `7.14`); parameterized so pure tests bind
  `insecureLocalDekCipher`.
- A clear, safe sealed-Vault error that starts no Pulumi command and names `prodbox vault unseal`.

### Validation

- `cabal test --builddir=.build test:prodbox-integration --test-options='-p "Sprint 1.37"'` passed.
- Real `prodbox aws stack eks reconcile` dispatch refuses with the sealed-Vault error when the
  gate sees a sealed Vault; no Pulumi command is started. Dry-run paths render the plan without
  probing Vault.
- Unit tests cover the readiness-check decision, the redacted error, dry-run no-probe behavior, and
  the `TransitCipher` wrap/unwrap seam against a mock (no live Vault).

### Remaining Work

None for Sprint `1.37`. The Model-B object-store that consumes the `TransitCipher` lands in Sprint
`4.30`; the decrypt-to-scratch Pulumi interposition that envelopes the whole checkpoint through the
§9 object-store lands in Sprint `7.14`.

## Sprint 1.38: Config SSoT Inversion and Root-Token-Gated Config Authority ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/Config/Basics.hs`, `src/Prodbox/Config/InForce/Core.hs`, `src/Prodbox/Config/InForce.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/Repo.hs`, `src/Prodbox/Infra/MinioBackend.hs`
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/cluster_federation_doctrine.md`

**Current state (2026-06-14)**: the **pure framing** has **landed and validated**.
`Prodbox.Config.Basics` lands the typed `UnencryptedBasics` (cluster id / Vault address / `SealMode` /
optional `ParentRef` / format version) with deterministic JSON serialization, `validateBasics`
(including the seal-mode↔parent-ref coherence rule — a Shamir root has no parent, a Transit child
must carry one), and `isRootCluster`. `Prodbox.Config.InForce` lands the in-force-object identity +
cluster-bound AAD, `sealInForcePayload` / `openInForcePayload` over a `Prodbox.Crypto.Envelope`
`DekCipher` (the in-force config round-trips through the `prodbox-envelope-v1` envelope and fails
closed under a wrong cluster id, on tamper, and never leaks the config plaintext), the pure
`seedProposeDecision` (seed / propose / use-as-is / none), and the pure `rootConfigWriteDecision` +
`renderRootConfigWriteBlock` root-token-required precondition. 21 unit tests cover all four. Gates
green: `dev check` 0, `dev docs check` 0, `test unit` **906/906**. `SecretRef` is already
`FileSecret`-free (Sprint `1.35`).

**Update (2026-06-15)**: the **host-side IO seams** have **landed and validated**. `ConfigPaths`
now carries the sealed-state-readable basics path
`.data/prodbox/unencrypted-basics.json`; `loadUnencryptedBasics` / `writeUnencryptedBasics`
round-trip and validate that JSON surface. `decodeConfigDhallBytes` materializes an in-force Dhall
payload beside `prodbox-config-types.dhall` so the normal Dhall import resolver decodes it.
The injected `fetchInForceConfigWith` /
`storeInForceConfigWith` compose injected fetch/store IO with the `DekCipher`, envelope open/seal,
and Dhall decode. Gates green:
`cabal test --builddir=.build prodbox-unit --test-options='--hide-successes'` **926/926**.

**Closure update (2026-06-16)**: the **global host-loader switch** is implemented and validated.
Sprint `4.30` subsequently removed the interim
`active-config/in-force-config.prodbox-envelope-v1` backend helpers and routed the production read
through the Model-B object-store.
`Prodbox.Config.InForce.Core` now holds the cycle-free in-force framing used by
`Prodbox.Settings`; `validateAndLoadSettings` calls `loadConfigForSettingsWith`, which uses
repo-root `prodbox-config.dhall` only while unencrypted basics are absent (first-bring-up seed
mode). Once `.data/prodbox/unencrypted-basics.json` exists, settings loads validate those basics,
recover a ready Vault root token, read `secret/minio/root`, build the production
`vaultTransitDekCipher`, port-forward to MinIO, fetch the in-force envelope, and decode the Dhall
payload. Targeted Sprint `1.38` unit coverage passed **31/31**; full validation passed
`./.build/prodbox test unit` **910/910**, `./.build/prodbox test integration cli` **36/36**,
`./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`,
`./.build/prodbox dev lint chart`, and `./.build/prodbox dev check`.

### Objective

Invert the config source of truth: the **in-force cluster configuration** is a
Vault-Transit-enveloped object in MinIO, not the filesystem `prodbox-config.dhall`. A filesystem
Dhall file is a seed/propose input only — it seeds the encrypted MinIO SSoT on first-ever bring-up
and is a proposed update thereafter. Reads of the **unencrypted basics** are always free; full
reads require an unsealed Vault; **root-cluster config writes require the root Vault token**, because
the root config governs every downstream cluster
([config_doctrine.md §1/§5/§6](../documents/engineering/config_doctrine.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md)).

### Deliverables

- The in-force config is stored in MinIO as a `prodbox-envelope-v1` Vault-Transit envelope and is
  the SSoT; a sealed Vault leaves it opaque ciphertext, revealing nothing beyond the unencrypted
  basics.
- An **unencrypted-basics** local surface — cluster id, this cluster's Vault address, seal mode,
  and (for a child) the parent reference it must contact to auto-unseal — sufficient only to reach
  and unseal Vault, revealing nothing about workloads, downstream clusters, or credentials.
- The host CLI reads the basics locally, then fetches and decrypts the in-force config from MinIO
  via Vault; the prior "read repo-root `prodbox-config.dhall` directly as the config SSoT" model is
  retired (queued in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), Sprint
  `1.38`).
- Supplying a filesystem `prodbox-config.dhall` is a seed (first-ever bring-up) or a proposed update
  (thereafter); it is never re-read as the live config.
- Updating the **root** cluster's in-force config requires the root Vault token (which requires an
  unsealed root Vault); reads of the basics are free, full reads require unseal.
- Finalize `SecretRef` without a `FileSecret` arm (closing the Sprint `1.35` deletion against the
  in-force-config path).

### Validation

- With Vault sealed, only the unencrypted basics are readable; the in-force config is opaque
  ciphertext and no downstream-cluster or credential data is determinable.
- A root-config write attempted without the root Vault token is refused; the same write succeeds
  once the root token is presented against an unsealed root Vault.
- On first-ever bring-up a filesystem `prodbox-config.dhall` seeds the encrypted MinIO SSoT; a
  later filesystem file is treated as a proposed update, not the live config.

### Remaining Work

None for Sprint `1.38`. Sprint `4.32` wires the lifecycle bootstrap/in-force-settings split for
federated child reconcile; replacing the interim meaningful MinIO key with the Model-B opaque
object store is Sprint `4.30`.

## Sprint 1.39: Tier 0: Binary-Owned prodbox.dhall in hostbootstrap Binary-Context Shape ✅

**Status**: ✅ Done (code-owned surface, validated 2026-06-17); 🧪 Live-proof pending (live `vault init` floor-write + read-on-rebuild on a real cluster)
**Implementation**: `src/Prodbox/Config/Tier0.hs` (new), `src/Prodbox/Settings.hs`, `src/Prodbox/Repo.hs`, `src/Prodbox/CLI/Vault.hs`, `prodbox.cabal`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`
**Blocked by**: Sprint `1.38` (closed)

### Objective

Collapse the non-secret config surface into one binary-owned **Tier 0** artifact — a project-local
`prodbox.dhall` carrying `{parameters, context, witness}` and **never** secrets — shaped to align
with `hostbootstrap`'s binary-context contract so the eventual refactor onto `hostbootstrap` is a
clean extension rather than a rewrite. This folds the former `.data/prodbox/unencrypted-basics.json`
**and** the non-secret sections of the seed/propose `prodbox-config.dhall` into the single Tier 0
file, while a small **derived** `prodbox-basics.json` remains the dependency-free sealed-Vault
bootstrap floor read before Vault is reachable. Tiers 1–2 are untouched: secrecy stays prodbox's
additive layer over the shared non-secret base
([config_doctrine.md §0 (Three-Tier Config Model)](../documents/engineering/config_doctrine.md#0-three-tier-config-model),
[config_doctrine.md §1a (in-force config in MinIO)](../documents/engineering/config_doctrine.md#1a-the-in-force-config-lives-encrypted-in-minio),
[config_doctrine.md §3 (Canonical paths)](../documents/engineering/config_doctrine.md#3-canonical-paths)).

### Deliverables

- A binary-owned, project-local `prodbox.dhall` with a `{parameters, context, witness}` shape carrying
  only non-secret config (cluster id, this cluster's Vault address, seal mode, optional parent
  reference, public-edge inputs, and the rest of the former non-secret `prodbox-config.dhall`
  sections) and **no** secret fields — only `SecretRef.Vault` pointers, never secret values
  ([config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model)).
- The Tier 0 schema is generated from the Haskell record (one typed source of truth) and emitted into
  `prodbox-config-types.dhall`; `decode . encode == id` round-trips for the Tier 0 record
  (composing with the Sprint `1.11` round-trip property invariant).
- `.data/prodbox/unencrypted-basics.json` is **folded into** `prodbox.dhall`: the `UnencryptedBasics`
  fields (Sprint `1.38`) become the `context`/`parameters` of the Tier 0 record rather than a
  separate JSON surface, and the standalone basics file is queued for removal in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
- A small **derived** `prodbox-basics.json` is **projected** from `prodbox.dhall` as the
  dependency-free sealed-Vault bootstrap floor — read before Vault is reachable, sufficient only to
  reach and unseal Vault, revealing nothing about workloads, downstream clusters, or credentials
  ([config_doctrine.md §3](../documents/engineering/config_doctrine.md#3-canonical-paths)).
- The Tier 0 record maps onto `hostbootstrap`'s `BinaryContext` shape (`parameters`, `context`,
  `witness`) so a later refactor onto `hostbootstrap` is an extension; this alignment is recorded in
  [config_doctrine.md §0 (the balance principle)](../documents/engineering/config_doctrine.md#0-three-tier-config-model).
- `validateAndLoadSettings` (Sprint `1.38`) reads Tier 0 from `prodbox.dhall` (projecting
  `prodbox-basics.json` for the sealed-Vault floor), then fetches/decrypts the Tier 2 in-force config
  through Vault as before; the seed/propose decision over a supplied filesystem file is unchanged.

### Validation

- `decode . encode == id` for the Tier 0 record, and `prodbox-basics.json` is byte-deterministically
  projected from `prodbox.dhall` (the derivation is a pure function of Tier 0).
- With Vault sealed, the projected `prodbox-basics.json` is sufficient to reach and unseal Vault and
  reveals nothing beyond the bootstrap floor; the Tier 2 in-force config stays opaque ciphertext.
- The Tier 0 `prodbox.dhall` carries no secret values — only `SecretRef.Vault` pointers — asserted by
  a unit test over the decoded record.
- `prodbox dev check`, `prodbox test unit`, and `prodbox test integration cli` pass on the folded
  Tier 0 surface.

### Remaining Work

Code-owned surface landed and validated 2026-06-17: `src/Prodbox/Config/Tier0.hs` defines the
`ProdboxProjectConfig { parameters, context, witness }` record (hostbootstrap `BinaryContext`-aligned —
`context_kind`, `cluster_id`, `vault_address`, MinIO coordinates, `topology { seal_mode, parent_ref }`,
`capabilities` incl. `DurableStore`); `parameters` carries the non-secret config sections with `aws.*` /
`acme.eab_*` as `SecretRef.Vault` pointers only. `renderProjectConfigDhall` renders `prodbox.dhall` from the
Haskell record (schema = one typed SoT; `decode . encode == id` round-trip test), `projectBasics` /
`projectBasicsJson` deterministically derive the dependency-free `prodbox-basics.json` floor (reusing Sprint
`1.38` `basicsToJson`), `tier0CarriesNoSecretValues` is the secret-free guard, and `writeTier0` writes
`prodbox.dhall` + derives the floor (wired into `initFreshVault`). `loadUnencryptedBasics` /
`loadConfigForSettingsWith` now resolve the floor via `resolveBasicsFloorPath` (prefer `prodbox-basics.json`,
fall back to the legacy `.data/prodbox/unencrypted-basics.json` — backward-compat shim; legacy file queued in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)). Gate: `dev check` 0, `test unit` 0
(972, incl. 6 new Tier-0 tests), `test integration cli` 0 (39), `test integration env` 0 (39). The
in-cluster container-default `prodbox.dhall` + cluster-daemon ConfigMap overwrite are owned by Sprint `1.40`;
the live floor-write/read-on-rebuild proof is the 🧪 Live-proof-pending axis.

## Sprint 1.40: Tier 0 In-Cluster: Container Default prodbox.dhall + Cluster-Daemon ConfigMap Overwrite ✅

**Status**: ✅ Done (code-owned surface, validated 2026-06-18); 🧪 Live-proof pending (in-cluster ConfigMap-overwrite reload on a deployed daemon)
**Implementation**: `src/Prodbox/Config/Tier0.hs`, `docker/default-prodbox.dhall` (new, `TrackedGeneratedPath`), `docker/gateway.Dockerfile`, `docker/prodbox.Dockerfile`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`
**Blocked by**: Sprint `1.39`, Sprint `1.38` (closed)

### Objective

Carry the **Tier 0** binary-context surface into the cluster: the built prodbox **container** ships a
default `prodbox.dhall`, and the cluster daemon **overwrites** it from a ConfigMap on startup —
`hostbootstrap`'s per-frame context-init pattern. The ConfigMap-overwrite path already exists today
(`gateway-config-<nodeId>` mounted at `/etc/gateway/config` as a directory mount, so kubelet's atomic
`..data` swap fires the fsnotify reload); the gap this sprint closes is the **in-container default**
`prodbox.dhall` plus the binary-context shape and rename. Secrets remain `SecretRef.Vault` pointers
resolved at daemon startup via the daemon's Vault Kubernetes-auth identity — no Secret-mounted Dhall
credential fragments
([config_doctrine.md §0 (Three-Tier Config Model)](../documents/engineering/config_doctrine.md#0-three-tier-config-model),
[config_doctrine.md §3 (Canonical paths)](../documents/engineering/config_doctrine.md#3-canonical-paths),
[config_doctrine.md §6 (Cluster mount contract)](../documents/engineering/config_doctrine.md#6-cluster-mount-contract);
mount contract owned by
[distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md)).

### Deliverables

- The built prodbox container (`docker/prodbox.Dockerfile`) ships a baked-in **default**
  `prodbox.dhall` Tier 0 file so a freshly started container has a valid binary context before any
  ConfigMap is mounted ([config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model)).
- The cluster daemon **overwrites** the in-container default from the existing
  `gateway-config-<nodeId>` ConfigMap mounted at `/etc/gateway/config` (directory mount; kubelet's
  atomic `..data` symlink swap fires the fsnotify reload), consuming the Tier 0 record shape from
  Sprint `1.39` ([config_doctrine.md §6](../documents/engineering/config_doctrine.md#6-cluster-mount-contract)).
- The Tier 0 in-container default and the ConfigMap payload share one schema (the Sprint `1.39`
  Haskell-generated Tier 0 record); the daemon's loader (`src/Prodbox/Gateway/Settings.hs`) decodes
  the same `{parameters, context, witness}` shape the host CLI reads.
- Secrets are never carried in the ConfigMap or the container default — only `SecretRef.Vault`
  pointers, resolved at daemon startup through Vault Kubernetes auth
  ([config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model)).
- The rename from the prior `config.dhall`/`unencrypted-basics.json` surfaces to the Tier 0
  `prodbox.dhall` binary-context name is queued in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

- A container started with no ConfigMap mount decodes its baked-in default `prodbox.dhall` to a valid
  Tier 0 binary context.
- Mounting/updating the `gateway-config-<nodeId>` ConfigMap overwrites the in-container default and
  fires the existing fsnotify reload via kubelet's atomic `..data` swap; the daemon reloads the new
  Tier 0 context without restart.
- The ConfigMap and container default carry no secret values (only `SecretRef.Vault` pointers),
  asserted by a unit test over the decoded daemon context.
- `prodbox dev check`, `prodbox test unit`, and the daemon-lifecycle suite pass on the in-cluster
  Tier 0 surface.

### Remaining Work

Code-owned surface landed and validated 2026-06-18. `Prodbox.Config.Tier0` gained the `Daemon`-frame
binary context (`defaultDaemonContext` / `defaultDaemonProjectConfig` — `binary = "gateway"`,
`context_kind = Daemon`, reusing the shared `defaultProdboxParameters` so host CLI and daemon decode the
identical `{parameters, context, witness}` schema and the secret-free guard holds), `renderDaemonContainerDefaultDhall`,
a `Tier0Source` provenance ADT, and `loadDaemonBinaryContext` — the per-frame context-init loader: prefer the
ConfigMap-mounted `prodbox.dhall` (overwrite), else the baked-in container default at `/etc/prodbox/prodbox.dhall`,
else the compiled-in default. `docker/default-prodbox.dhall` is the byte-for-byte render of the Haskell default,
registered as a `TrackedGeneratedPath` (drift-guarded by `dev check`) and `COPY`-ed into both
`docker/gateway.Dockerfile` and `docker/prodbox.Dockerfile`. `runGatewayDaemon` logs the resolved Tier-0 context
+ provenance at startup (additive; a decode failure is a warning, never fatal — the operational `DaemonConfig`
runtime is untouched). Gate: `dev check` 0, `test unit` 0 (979, incl. 7 new Sprint 1.40 tests), `test integration
cli` 0 (39), `test integration env` 0 (39), `dev docs check` 0, `dev lint docs` 0.

**Deferred (pragmatic scope):** the daemon's existing operational runtime config
(`DaemonConfigDhall { schemaVersion, vault, boot, live }` at `/etc/gateway/config/config.dhall`) is **not** folded
into the Tier-0 record — a deep, high-risk merge (boot/live split, the `daemonBootFieldsChanged` fsnotify
classifier, `reloadLiveConfig`, the SecretRef-resolution path, the gateway chart ConfigMap/Deployment). The
Tier-0 binary-context path is added **alongside** it without destabilizing the daemon; full unification is a
follow-on. **Pre-existing breakage discovered (not caused by this sprint):** the standalone `prodbox-daemon-lifecycle`
cabal suite is 8/11 red because its `test/daemon-lifecycle/Main.hs::renderConfig` fixture still emits the old
plaintext `event_keys`/`aws_creds`/`minio_creds` shape instead of the current `SecretRef` union (schema drift
predating the Vault-root migration; reproduced on pristine HEAD). It is not part of the `prodbox test` frontend
gate; queued as a fixture-repair follow-up. Tier 1 / Tier 2 are unchanged by this sprint.

## Sprint 1.41: Config-Topology Consolidation: Drop the JSON Floor + All Dhall Generated/Not-Version-Controlled ✅

**Status**: ✅ Done (code-owned surface, validated 2026-06-18; live home `cluster reconcile` RC=0 reads the floor from `prodbox.dhall` with `prodbox-basics.json` gone + not regenerated, and schemas materialized before decode)
**Implementation**: `src/Prodbox/Config/FloorDhall.hs` (new — cycle-free floor reader: decodes `prodbox.dhall` `context` → `UnencryptedBasics`), `src/Prodbox/Config/Tier0.hs` (`writeTier0` writes only `prodbox.dhall`; dropped `projectBasicsJson`), `src/Prodbox/Settings.hs` (`loadUnencryptedBasics` re-exported from `FloorDhall`; dropped the JSON reader / `resolveBasicsFloorPath` / `writeUnencryptedBasics`), `src/Prodbox/Repo.hs` (dropped `configBasicsDerivedPath` + `configBasicsPath`), `src/Prodbox/Vault/Host.hs` (`resolveBootstrapClusterId` via `FloorDhall`), `src/Prodbox/CheckCode.hs` (dropped the `docker/default-prodbox.dhall` `TrackedGeneratedPath`), `src/Prodbox/CLI/Rke2.hs` (`ensureDaemonContainerDefaultDhall` regenerates `docker/default-prodbox.dhall` into the build context inside `buildCustomImageOnce` before every `docker build`, both substrates), `src/Prodbox/App.hs` (`materializeSchemaFilesIfStale` before `runNativeCommand` so a schema-less checkout decodes), `docker/{gateway,prodbox}.Dockerfile`, `.gitignore`, `.dockerignore`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/config_doctrine.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Blocked by**: Sprint `1.39`, Sprint `1.40` (closed)

### Objective

Collapse the Tier-0 surface to a single self-contained artifact and finish the "no version-controlled
Dhall" posture. The sealed-Vault bootstrap floor is read **directly** from the self-contained Tier-0
`prodbox.dhall` via `projectBasics` — there is **no** separate JSON floor: `prodbox-basics.json` (the
derived bootstrap floor) and the legacy `.data/prodbox/unencrypted-basics.json` fallback are both
eliminated. Concurrently, every `.dhall` becomes either generated or locally-authored and **none** is
version-controlled, so the repository carries zero tracked Dhall
([config_doctrine.md §0 (Three-Tier Config Model)](../documents/engineering/config_doctrine.md#0-three-tier-config-model),
[config_doctrine.md §1a (in-force config in MinIO)](../documents/engineering/config_doctrine.md#1a-the-in-force-config-lives-encrypted-in-minio),
[config_doctrine.md §3 (Canonical paths)](../documents/engineering/config_doctrine.md#3-canonical-paths)).

### Deliverables

- The sealed-Vault bootstrap floor is read directly from the self-contained Tier-0 `prodbox.dhall`
  via `projectBasics` (the binary decodes the no-imports Tier-0 file and projects the basics);
  `configBasicsDerivedPath` and the legacy unencrypted-basics.json fallback in
  `resolveBasicsFloorPath` are dropped, and the derived `prodbox-basics.json` write
  (`projectBasicsJson` / `writeTier0`'s floor-derive step) is removed
  ([config_doctrine.md §3](../documents/engineering/config_doctrine.md#3-canonical-paths)).
- `prodbox-basics.json` (the derived JSON bootstrap floor) is **eliminated** — the floor lives only in
  `prodbox.dhall` — and both it and the legacy `.data/prodbox/unencrypted-basics.json` are recorded as
  removed in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
- `docker/default-prodbox.dhall` becomes **generated at image-build time**: it is rendered from
  `renderDaemonContainerDefaultDhall` into the build context immediately before `docker build` (rather
  than living as a committed `TrackedGeneratedPath`), is git-ignored, and its `CheckCode`
  `TrackedGeneratedPath` registration is removed
  ([config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model)).
- The generated schemas `prodbox-config-types.dhall` and `test-config-types.dhall` stay
  Haskell-generated and become git-ignored (a one-time operator
  `git rm --cached prodbox-config-types.dhall test-config-types.dhall` untracks them); combined with
  the generated `prodbox.dhall` / `docker/default-prodbox.dhall` and the locally-authored
  `prodbox-config.dhall` / `test-config.dhall` seeds, the net result is **zero version-controlled
  `.dhall`** ([config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model)).
- Tiers 1–2 are untouched: this sprint only consolidates the Tier-0 non-secret surface and the
  generated-artifact posture.

### Validation

- The sealed-Vault floor is projected from `prodbox.dhall` alone (no `prodbox-basics.json`,
  no `.data/prodbox/unencrypted-basics.json`); a unit test asserts `projectBasics` over the decoded
  self-contained Tier-0 record yields the bootstrap floor and that the JSON-floor code paths are gone.
- `docker/default-prodbox.dhall` is byte-deterministically rendered from
  `renderDaemonContainerDefaultDhall` at build time and is absent from version control; `dev check`
  no longer drift-guards a committed copy.
- `git ls-files '*.dhall'` returns empty after the operator untracks the generated schemas.
- `prodbox dev check`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` pass on the consolidated surface, and a live cluster reconcile reads
  the sealed-Vault floor from `prodbox.dhall`.

### Remaining Work

In progress. The Tier-0 self-contained floor-read, the JSON-floor elimination, the build-time render of
`docker/default-prodbox.dhall`, and the `.gitignore` untracking of the generated schemas land together;
the live cluster-reconcile floor-read is the 🧪 Live-proof axis. The in-force MinIO SSoT seed and the
retirement of the `prodbox-config.dhall` seed are owned by Sprint `1.42`.

## Sprint 1.42: Seed the In-Force MinIO SSoT + Retire the prodbox-config.dhall Seed ✅

**Status**: ✅ Done (Part A 2026-06-18, Part B 2026-06-19). **Part A (seed the in-force SSoT)**: the unwired
`storeInForceConfigWith` is wired via `seedInForceConfigFromFileWithToken` (`src/Prodbox/Settings.hs`,
the PUT-twin of the read path) into the post-MinIO/post-Vault-unseal reconcile step
(`loadPostMinioLifecycleSettings` / `seedInForceConfigStep`, `src/Prodbox/CLI/Rke2.hs`, root + child arms),
gated by `seedProposeDecision` (only `SeedInForce` writes). Live home `cluster reconcile` proved it
end-to-end (1st run RC=0 seeds; 2nd run RC=0 `UseInForceAsIs`, idempotent). **Part B (retire
`prodbox-config.dhall`)**: the standalone seed file is RETIRED. The operator's non-secret config now lives
in the binary-generated, git-ignored Tier-0 `prodbox.dhall` (operator decision 2026-06-19 — there is no
hand-authored seed file; `config setup` generates `prodbox.dhall`). Implemented:
`Settings.loadConfigFile` now decodes `( <prodbox.dhall> ).parameters` (the `parameters` sub-record is
structurally a `ConfigFile`; Dhall field-projection keeps `Settings` free of the `Tier0`↔`Settings` import
cycle); the in-force SSoT payload decoder is split out as `Settings.decodeConfigFileAtPath` (still
materialises a temp `prodbox-config.dhall` + `prodbox-config-types.dhall` schema — that internal SSoT shape
is unchanged); `config setup` / `aws setup` author into `prodbox.dhall`'s `parameters` via
`Tier0.writeOperatorParametersToTier0` (merge-write preserving `context`/`witness`); `vault init` preserves
operator `parameters` via `Tier0.writeTier0FloorPreservingParameters`; ~35 test fixtures author a Tier-0
`prodbox.dhall` via the new `TestSupport.wrapTier0` helper; all `src` user-facing messages/help/errors
referencing `prodbox-config.dhall` repointed to `prodbox.dhall`.
**Establishment signal + no fallback (operator decision 2026-06-19)**: `loadConfigForSettingsWith` reads the
in-force SSoT when the cluster is *established* — signalled by the Vault unlock bundle's presence — and the
operator-authored `prodbox.dhall` `parameters` before establishment (first bring-up + every host test with
no cluster). A sealed or unreachable Vault on an established cluster is **NOT** a fail-closed brick that
falls back to `parameters`: the cluster keeps running and simply cannot read its config (no fallback).
🧪 Live-proof: pending — a from-scratch home bring-up reads config from `prodbox.dhall`/the seeded SSoT with
no `prodbox-config.dhall` present (non-blocking, Standard O). **Hermeticity caveat**: the three
`cluster reconcile` CLI integration tests exercise the reconcile seed step against the host Vault via the
existing `PRODBOX_TEST_HOST_VAULT_TOKEN` seam (green on the canonical Bathurst host); a future seam for a
fully Vault-less host is tracked as a follow-up, non-blocking.
**Implementation**: `src/Prodbox/Settings.hs` (`loadConfigFile`, `decodeConfigFileAtPath`,
`loadConfigForSettingsWith`), `src/Prodbox/Config/Tier0.hs` (`configFileToTier0Parameters`,
`writeOperatorParametersToTier0`, `writeTier0FloorPreservingParameters`), `src/Prodbox/Aws.hs`
(`writeProjectConfigParameters`, `loadConfigForWrite`), `src/Prodbox/CLI/Vault.hs` (`writeTier0BasicsFloor`),
`test/support/TestSupport.hs` (`wrapTier0`), `test/{unit/Main.hs,integration/CliSuite.hs,integration/EnvSuite.hs}`.
**Docs to update**: `documents/engineering/config_doctrine.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Independent Validation**: validated on the host CLI's code-owned surface — `dev check`, `test unit`,
`test integration cli`/`env` all green — with no dependency on a later phase; the SSoT/Vault path is exercised
against the home substrate and host test seams.
**Blocked by**: Sprint `1.38`, Sprint `1.39`, Sprint `1.41` (all closed)

### Objective

Wire `storeInForceConfigWith` — which has **zero production callers today** (the twin of the
`writeUnencryptedBasics` / `ensureBasicsFloor` floor-write gap) — so first-ever bring-up **seeds** the
encrypted in-force MinIO SSoT (Vault-Transit envelope, opaque object name) from the operator config,
and thereafter the cluster reads its config from the SSoT rather than the seed-fallback. Once seeded,
**retire** the legacy `prodbox-config.dhall` seed/propose input: its non-secret operator config
(route53 zone, SES domains, ACME email, Pulumi bucket) now lives in the SSoT
([config_doctrine.md §0 (Three-Tier Config Model)](../documents/engineering/config_doctrine.md#0-three-tier-config-model),
[config_doctrine.md §1a (in-force config in MinIO)](../documents/engineering/config_doctrine.md#1a-the-in-force-config-lives-encrypted-in-minio),
[config_doctrine.md §3 (Canonical paths)](../documents/engineering/config_doctrine.md#3-canonical-paths)).

### Deliverables

- `storeInForceConfigWith` is wired into the first-bring-up path so the operator config is enveloped
  into the encrypted MinIO SSoT (Vault-Transit, opaque `objects/<id>.enc` name) on first-ever
  bring-up; the Sprint `1.39` `inForceConfigObjectAbsent` seed-fallback remains the interim only until
  the SSoT is seeded ([config_doctrine.md §1a](../documents/engineering/config_doctrine.md#1a-the-in-force-config-lives-encrypted-in-minio)).
- After seeding, `validateAndLoadSettings` reads the in-force config from the seeded SSoT (decrypted
  through Vault) rather than the filesystem seed-fallback
  ([config_doctrine.md §1a](../documents/engineering/config_doctrine.md#1a-the-in-force-config-lives-encrypted-in-minio)).
- The legacy `prodbox-config.dhall` seed/propose input is retired: it carries **no plaintext secrets**
  (verified — only `SecretRef.Vault` pointers: `aws.*` → `secret/gateway/gateway/aws`,
  `acme.eab_*` → `secret/acme/eab`; the test secrets already live in `test-config.dhall`), and its
  non-secret operator config now lives in the SSoT, so its deletion is queued in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). Retirement is **gated** on the
  SSoT being seeded — until then the operator non-secret config lives only in `prodbox-config.dhall`
  (`prodbox.dhall` carries empty defaults).

### Validation

- First-ever bring-up seeds the encrypted in-force SSoT (one opaque Vault-Transit MinIO object) from
  the operator config; a unit/integration test asserts `storeInForceConfigWith` is invoked on the
  no-SSoT-yet path.
- 🧪 Live-proof: a rebuild reads the in-force config from the seeded SSoT with `prodbox-config.dhall`
  **absent** (the seed-fallback is no longer consulted once the SSoT exists).
- `prodbox dev check`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` pass with the seed wired.

### Remaining Work

None (code-owned surface). The standalone `prodbox-config.dhall` seed file is retired; the operator's
non-secret config is the binary-generated, git-ignored Tier-0 `prodbox.dhall`. The only outstanding axis is
the non-blocking 🧪 Live-proof above (a from-scratch home bring-up reading config with no
`prodbox-config.dhall` present). The operator's expanded config/secrets target — splitting the test secrets
into a dedicated `test-secrets.dhall` and routing the Vault-written secrets through the gateway daemon — is
scheduled as the new Sprints `1.43` and `1.44` below.

## Sprint 1.43: Split test-secrets.dhall (the sole durable-secret fixture) ✅

**Status**: ✅ Done (2026-06-20). `TestConfig` → `TestSecrets` (the harness secrets fixture), the
former `test-config.dhall` renamed to `test-secrets.dhall`, and — because the fixture carried no
non-secret toggles — the now-empty `test-config.dhall` / `test-config-types.dhall` were removed
outright (the sprint's "removed if empty" branch). `test-secrets.dhall` is the sole durable-secret
fixture file (operator decision 2026-06-19).
**Implementation**: `src/Prodbox/Vault/Host.hs` (`TestConfig`→`TestSecrets`,
`TestConfigAdminCredentials`→`TestSecretsAdminCredentials`, `loadTestSecrets`, `testSecretsPath`,
`obtainOperatorPassword`/`obtainNewOperatorPassword`, `seedAcmeEabFromTestSecrets`),
`src/Prodbox/Config/SchemaDhall.hs` (generates `test-secrets-types.dhall` via `prodbox config schema`),
`src/Prodbox/Aws/AdminCredentials.hs` (`acquireAdminAwsCredentials`), `src/Prodbox/Native.hs`,
`src/Prodbox/Aws.hs` / `src/Prodbox/CLI/Rke2.hs` (seeder callers), the golden CLI/destructive outputs,
`test/unit/Main.hs` + `test/integration/CliSuite.hs`, and `.gitignore`.
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/vault_doctrine.md`,
and the rest of the governed docs that named the fixture (all renamed to `test-secrets.dhall`),
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Blocked by**: Sprint `1.42` (closed)
**Independent Validation**: `test unit` 1046/1046 (incl. the schema-drift round-trip), `test integration
cli`/`env` pass on the host CLI surface; no later-phase dependency.

### Objective

Move the only durable secrets the test harness carries — `vault_operator_password`,
`aws_admin_for_test_simulation.*` (durable elevated AWS credentials), and `acme_eab` (the ZeroSSL EAB
key) — into a dedicated, git-ignored `test-secrets.dhall` (operator decision 2026-06-19:
`test-secrets.dhall` is the only place durable elevated AWS credentials and the ACME key live).

### Deliverables

- The `TestSecrets` Haskell record (source of truth) split out of the former `TestConfig`, with a
  generated `test-secrets-types.dhall` schema emitted by `prodbox config schema`. Because the fixture
  held no non-secret toggles, the now-empty `test-config.dhall` and its `test-config-types.dhall`
  schema were removed rather than kept as a dead empty record (the sprint's "removed if empty" clause).
- `obtainOperatorPassword`, `acquireAdminAwsCredentials`, and `seedAcmeEabFromTestSecrets` read from
  `test-secrets.dhall`.
- The schema-drift round-trip guard and all fixtures are updated; `.gitignore` covers
  `test-secrets.dhall` and the generated `test-secrets-types.dhall`.

### Validation

`test unit` (incl. the schema-drift round-trip) 1046/1046, `test integration cli`/`env` pass; a grep
confirms no `test-config*.dhall` reference remains in `src/`, `test/`, `documents/`, or the goldens.

### Remaining Work

None (code-owned surface). The live home reconcile/rebuild that reads the relocated fixture is the
non-blocking 🧪 Live-proof axis shared with the broader config-SSoT live proof.

## Sprint 1.44: Route Vault-written secrets through the gateway daemon (simulated CLI → NodePort) ✅

**Status**: ✅ Done on the code-owned surface (2026-06-20); 🧪 Live-proof pending. The write-capable
gateway-daemon endpoint, the dedicated operator-write Vault policy/role, the host CLI client write
method, and the harness rewiring all land and are unit-tested; the live home run that actually routes
the EAB + operational `aws.*` through the daemon NodePort is the non-blocking 🧪 axis (Standard O).
**Implementation**: `src/Prodbox/Gateway/Daemon.hs` (`POST /v1/secret/<logical>` with the
`allowedOperatorSecretPaths` allowlist, `X-Prodbox-Operator-Jwt` auth, `operatorWriteRoleName` Vault
login, `writeOperatorSecret`; the read dispatch split into `handleReadRequest`),
`src/Prodbox/Gateway/Client.hs` (`operatorSecretUrl` + `writeOperatorSecret`),
`src/Prodbox/Vault/Reconcile.hs` (the `prodbox-operator-write` policy + Kubernetes auth role, distinct
from the read-only `prodbox-gateway-daemon`), `src/Prodbox/Aws.hs`
(`writeOperatorSecretViaDaemonOrHost` / `attemptOperatorDaemonWrite` / `mintOperatorWriteJwt`, wiring
`writeOperationalAwsVaultCredentials` + `writeAcmeEabVaultCredentials` through the daemon with a
host-write fallback).
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md` (§11 operator-write
endpoint), `documents/engineering/vault_doctrine.md` (§12 operator-write role/policy)
**Blocked by**: Sprint `1.43` (closed)
**Live-proof**: pending
**Independent Validation**: `test unit` 1046/1046 (+9 endpoint/policy/client unit tests), `test
integration cli`/`env` pass; the daemon write endpoint, allowlist, JWT header parsing, body decode,
Vault policy document, and client URL are unit-tested with no later-phase dependency.

### Objective

Load the Vault-written secrets into Vault by SIMULATING operator CLI interactions against the prodbox
NodePort → in-cluster gateway daemon, authenticated by a Vault-Kubernetes-operator-injected JWT (operator
decision 2026-06-19), replacing the host root-token direct Vault write for these objects.

### Deliverables

- A write-capable gateway-daemon REST endpoint (`POST /v1/secret/<logical>`) + a dedicated
  `prodbox-operator-write` Vault policy/role (the daemon's own `prodbox-gateway-daemon` policy stays
  read-only; the operator-write policy grants `create`/`update` on exactly the host-written
  `secret/data/gateway/gateway/aws` + `secret/data/acme/eab`). The endpoint exchanges the request's
  `X-Prodbox-Operator-Jwt` for a Vault token under that role; a non-`POST` method is `405`, a
  non-allowlisted path is `404`, a missing JWT is `401`, a failed login is `403`, a write failure is
  `502`, and unconfigured gateway Vault auth is `503`.
- A host CLI client write method (`Prodbox.Gateway.Client.writeOperatorSecret`) and the harness
  invoking it as simulated operator CLI calls (`writeOperatorSecretViaDaemonOrHost`, minting the JWT via
  `kubectl create token prodbox-operator-write -n gateway`, falling back to the host root-token write
  when the daemon path is unavailable so non-daemon contexts never regress).
- Scope: only the secrets actually written to Vault flow through the daemon — the ACME EAB
  (`secret/acme/eab`) and the **minted** operational `aws.*` (`secret/gateway/gateway/aws`). The
  `vault_operator_password` (the unlock-bundle decryption password, needed BEFORE Vault is unsealed) and the
  ephemeral `aws_admin_for_test_simulation` credential (used host-side to mint the IAM user, deliberately
  never stored in Vault) stay host-side — a daemon needing an already-unsealed Vault cannot bootstrap them.

### Validation

`test unit` (daemon endpoint + allowlist + JWT header + body decode + Vault policy + client URL)
1046/1046, `test integration cli`/`env` pass; 🧪 Live-proof (non-blocking): a home run loads the EAB +
operational `aws.*` into Vault via the daemon NodePort path under the `prodbox-operator-write` role.

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): a live home run that confirms the daemon path is taken
  (no host-write fallback diagnostic) for the EAB + operational `aws.*`. The
  `prodbox-operator-write` Kubernetes ServiceAccount must exist in the `gateway` namespace for the
  JWT mint to succeed; until then the harness falls back to the host root-token write.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
