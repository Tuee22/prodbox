# Phase 1: Haskell Runtime, CLI, Config, and Pulumi Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md), [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)

> **Purpose**: Capture the Haskell runtime, CLI, configuration, build, and Pulumi foundations that
> make later gateway, chart, and public-host phases meaningful and testable, and own the
> CLI-doctrine adoption sprints that align those foundations with
> [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md).

## Phase Status

🔄 **Active** — Sprints `1.1`–`1.5` remain `Done` on the Haskell-only rewrite baseline. The phase
is reopened by Sprint 0.2 (see
[phase-0-planning-documentation.md](phase-0-planning-documentation.md)) to schedule Sprints
`1.6`–`1.23`, which adopt the CLI doctrine across the CLI surface, runtime, configuration, test
harness, and lint stack and close the residual doctrine cleanup items (Dhall freeze, parser
`--foreground` default plus self-daemonization-forbidden rule, and the cross-language types
generation deferral). Sprint 0.3 extends the reopen to **Sprints `1.24`–`1.26`**, adding the
doctrine items surfaced by the May 2026 audit: durable CLI documentation artifacts, the
`execParserPure` parser-test category, and the `renderError` error-boundary discipline. Sprint
0.3 also extends the deliverable lists of Sprints 1.6 and 1.10 to require per-command
`CommandSpec` `Example` entries and the `cabal format` temp-file round-trip byte-equality
compare, respectively. Current worktree evidence puts Sprints `1.6`, `1.7`, `1.11`, and
`1.24` in `Active` state: the parser remains hand-authored rather than rendered from
`CommandSpec`, the full build/apply split is not yet generalized across state-changing
surfaces, the doctrinal single `prodbox-integration` stanza plus full property-invariant
closure remain incomplete, and durable CLI documentation currently stops at the generated
Markdown command reference. Sprints `1.10`, `1.20`, `1.25`, and `1.27` are now implemented in
code and validated locally. The remaining reopened Phase `1` sprints stay `Planned`.

## Phase Summary

This phase establishes the Haskell `prodbox` binary, the canonical Cabal build topology, the
repository-root Dhall config loader, the Haskell command runtime and test harness, and the Pulumi
foundations for true IaC plus AWS validation. It also owns the canonical frontend image placement
under `docker/`, the direct-Dhall config contract, the native validation harness, and the aligned
root guidance or engineering docs listed by its sprints. Later retirement of local-cluster
Pulumi ownership is Phase `4` work, not a change to the foundations closed here. Sprints `1.1`,
`1.2`, `1.3`, `1.4`, and `1.5` remain closed on the Haskell-only rewrite baseline. The phase
closes on the single-host public-edge config doctrine: one canonical public hostname,
`test.resolvefintech.com`, settings-backed MetalLB L2 or BGP rendering, explicit public-edge
scaling inputs, and Route 53 hosted-zone alignment enforced during supported config authoring. The
implemented frontend container doctrine uses
`ubuntu:24.04` with in-image `ghcup`, pinned GHC `9.14.1`, no symlinked Haskell tool shims, and
explicit repo package-bound updates.

Sprints `1.6` through `1.23` adopt the CLI doctrine from
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md). They split the CLI parser into a
`CommandSpec`-driven source of truth, introduce the `Plan` / `apply` discipline with
`--dry-run`, formalize the `Subprocess` ADT and its interpreter boundary, add a remedy-hint
contract to the prerequisite registry, align the lint stack on a pinned `fourmolu.yaml` plus
`GeneratedSectionRule`, `forbiddenPathRegistry`, and `.hlint.yaml` negative-space symbol rules,
migrate the test stanzas from `hspec` to `tasty`, introduce capability classes and first-class
retry policies, encode the `Recoverable | Fatal` error axis, centralize naming helpers and
smart-constructor patterns, re-encode multi-state workflows as GADT-indexed state machines,
reaffirm the GHC `9.14.1` / Cabal `3.16.1.0` toolchain pin, and close the residual doctrine
cleanup in Sprint `1.23` (Dhall freeze on `prodbox-config-types.dhall`, parser `--foreground`
default plus self-daemonization-forbidden rule, and the explicit cross-language-types
generation deferral). Sprints `1.24` through `1.26` close the residual doctrine gaps surfaced
by the May 2026 doctrine-vs-plan audit: Sprint `1.24` schedules the durable CLI documentation
artifacts (Markdown command reference, manpages, shell completion scripts) derived from the
`CommandSpec` registry; Sprint `1.25` schedules the `execParserPure` parser-test category;
Sprint `1.26` schedules the `renderError` error-boundary discipline plus hlint rules refusing
`print`, `exitFailure`, and direct terminal formatting in non-boundary code.

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
  `dist-newstyle/`, `.prodbox-state/`, and `.data/`, so retained PV content does not become a
  false-positive doctrine surface.
- The canonical frontend container build now lives at `docker/prodbox.Dockerfile`.
- `docker/prodbox.Dockerfile` now preserves the `/opt/build` artifact contract through in-image
  `ghcup` with pinned GHC `9.14.1` and Cabal `3.16.1.0`; no mounted `haskell:9.6.7-slim`
  BuildKit toolchain context or symlinked Haskell tool shims remain on the supported path.
- `cabal.project` now carries the repo-level `with-compiler: ghc-9.14.1` pin and the temporary
  `allow-newer: *:base, *:template-haskell` allowance required by the current package set, while
  `prodbox.cabal` carries the package-bound updates required by that toolchain.
- `test/integration/env/Main.hs` proves built-frontend config masking and validation directly
  against repository-root Dhall config without recreating `prodbox-config.json`.
- Named external-proof payloads behind `prodbox test integration ...` run executable native
  Haskell validation flows through `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/EffectInterpreter.hs`, and the AWS-backed
  runtime modules now strip ambient AWS auth and profile variables before projecting
  repository-root credentials into supported subprocesses.
- The current repository ships YAML Pulumi programs under `pulumi/aws-eks/Main.yaml` and
  `pulumi/aws-test/Main.yaml`. The public AWS validation stacks match the target Pulumi boundary.
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
**Implementation**: `app/prodbox/Main.hs`, `src/Prodbox/CLI/`, `src/Prodbox/Native.hs`, `prodbox.cabal`, `cabal.project`, `docker/prodbox.Dockerfile`, `docker/`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
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
  under `/opt/build`, installs `ghcup` in-image, pins GHC `9.14.1`, and does not create
  symlinked Haskell tool shims.
- `prodbox.cabal` and `cabal.project` are explicitly upgraded for the pinned GHC `9.14.1`
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
   `/opt/build` through in-image `ghcup`-managed GHC `9.14.1` with no symlinked Haskell tool
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
  `9.14.1`, and does not create symlinked Haskell tool shims.
- `prodbox.cabal` and `cabal.project` now implement the explicit repo upgrade required by the
  revised doctrine.
- `test/unit/Main.hs` and `test/integration/cli/Main.hs` now assert the `docker/prodbox.Dockerfile`
  location and the updated container-build doctrine.
- Root guidance docs and the governed docs listed in `Docs to update` are aligned in this change
  with the canonical Dockerfile location and the implemented `ghcup` plus `ghc-9.14.1` doctrine.

### Remaining Work

None.

## Sprint 1.2: Dhall Settings, Command ADTs, and Haskell Test Harness ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Native.hs`, `src/Prodbox/Repo.hs`, `test/unit/`, `test/integration/cli/`, `test/integration/env/`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/effect_interpreter.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/haskell_code_guide.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/prerequisite_dag_system.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/streaming_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the settings, interpreter, subprocess, and test contracts on Haskell-owned modules.

### Deliverables

- `prodbox-config.dhall` is decoded into typed Haskell settings values through the Haskell-owned
  `dhall-to-json` bridge.
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
  `.build/`, `dist-newstyle/`, `.prodbox-state/`, and `.data/`.
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
- `test/integration/cli/Main.hs` and `test/integration/env/Main.hs` remain the built-frontend
  proof surfaces for the Haskell-owned command surface.
- The root guidance docs and governed docs listed in `Docs to update` now describe the Haskell-only
  repository, the current validation harness, and the implemented `check-code` doctrine gate.
### Remaining Work

None.

## Sprint 1.3: Local Lifecycle and AWS Validation Foundations on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestRunner.hs`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `test/integration/cli/Main.hs`
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
  `src/Prodbox/Infra/AwsEksTestStack.hs` own the native AWS validation-stack orchestration.
- The repo-backed Pulumi prerequisite and AWS validation-stack helpers now use bounded
  `pulumi login ... --non-interactive` checks against the MinIO backend and recreate a deleted
  MinIO export host-path mount before restarting `deployment/minio`, so aggregate validation fails
  fast on real backend errors instead of hanging on stale retained-storage mounts.
- `src/Prodbox/TestValidation.hs` provides the named lifecycle, Pulumi, EKS, and HA-RKE2 AWS
  validation flows used by `prodbox test integration ...`.
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
- AWS validation doctrine remains explicit that MetalLB is a self-managed local-cluster surface,
  not an AWS validation-stack component.

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
  and the shared public-edge workload image during `prodbox rke2 reconcile`.
- `src/Prodbox/Aws.hs` now validates Route 53 hosted-zone alignment for the canonical hostname
  during `prodbox config setup`, while `src/Prodbox/TestValidation.hs` and the built-frontend
  suites align the config and lifecycle proofs with the one-host doctrine.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` remain the canonical validation gates for the single-host
  settings contract.

### Remaining Work

None.

## Sprint 1.6: CommandSpec Source-of-Truth Split 🔄

**Status**: Active
**Implementation**: `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Docs.hs`, `src/Prodbox/CLI/Tree.hs`, `src/Prodbox/CLI/Json.hs`, `src/Prodbox/App.hs`, `src/Prodbox/CLI/Parser.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → CommandSpec](../HASKELL_CLI_TOOL.md) and `Architecture →
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
  [../HASKELL_CLI_TOOL.md → Progressive Introspection](../HASKELL_CLI_TOOL.md). The audit is
  the source for the golden tests rather than an ad-hoc top-level subset.
- Every leaf `CommandSpec` node carries at least one `Example` entry per
  [../HASKELL_CLI_TOOL.md → Automatically Generated Documentation](../HASKELL_CLI_TOOL.md)
  §299–303 (`Example` records with `exampleCommand` and `exampleDescription`). A
  `prodbox-unit` property test (Sprint 1.11) asserts that the registry contains no leaf
  command with an empty `examples` list.
- Sprint 0.4 round-3 extension: bind the `CommandSpec` record fields explicitly:
  `name`, `summary`, `description`, `children`, `options`, `examples`, and bind the
  sibling `OptionSpec` record fields: `longName`, `shortName`, `metavar`,
  `description`, `required`, per
  [../HASKELL_CLI_TOOL.md → Automatically Generated
  Documentation](../HASKELL_CLI_TOOL.md) §283–304.
- Sprint 0.4 round-3 extension: bind the daemon-as-typed-`Command` dispatch
  pattern. Gateway daemon entry is a `GatewayDaemonCommand DaemonOptions`
  constructor on the top-level `Command` ADT (and any future daemon entry follows
  the same constructor shape rather than a separate argv parser) per
  [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Daemon as
  Command](../HASKELL_CLI_TOOL.md) §1156–1196. The `prodbox gateway start`
  subcommand defined in `src/Prodbox/CLI/Spec.hs` produces the
  `GatewayDaemonCommand` value; `Prodbox.App.run` dispatches to the daemon entry
  function through ordinary pattern matching with no separate parser.

### Validation

1. `cabal test prodbox-unit` and `cabal test prodbox-integration` (post Sprint 1.11).
2. `prodbox commands --json` emits a stable schema; the golden test passes.
3. Golden tests cover every leaf command's `--help` output, not just top-level help, per the
   progressive-introspection audit.
4. The pre-doctrine monolithic `src/Prodbox/CLI/Parser.hs` shape is enqueued in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. The leaf-`Example` property test fails when any new leaf `CommandSpec` is registered
   without at least one example.

### Remaining Work

- `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Docs.hs`, `src/Prodbox/CLI/Tree.hs`, and
  `src/Prodbox/CLI/Json.hs` are implemented, and `prodbox commands` / `prodbox help <path>`
  already run from `src/Prodbox/App.hs`.
- `src/Prodbox/CLI/Parser.hs` remains a hand-authored source of truth rather than a renderer of
  `CommandSpec`, and the parser has already drifted from the registry on doctrine-added surfaces
  such as Pulumi `--dry-run` / `--plan-file` and daemon flags.
- `src/Prodbox/CLI/Command.hs` still routes gateway operations through ad-hoc `GatewayCommand`
  constructors instead of a typed daemon-command value produced directly from the registry.
- `test/unit/Main.hs` contains selective parser assertions only; full leaf help/tree/json golden
  coverage and the leaf-`Example` completeness property test are still absent.

## Sprint 1.7: Plan / Apply Discipline with --dry-run 🔄

**Status**: Active
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Rke2.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/refactoring_patterns.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Plan / Apply](../HASKELL_CLI_TOOL.md) on every state-changing
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

- `PlanOptions`, `--dry-run`, `--plan-file`, and deterministic rendered plans are already wired
  through `prodbox charts deploy|delete` and `prodbox rke2 reconcile|install`.
- The doctrine's `build :: Inputs -> Either AppError Plan` / `apply :: Env -> Plan -> IO ExitCode`
  split is still absent from gateway, Pulumi, AWS, and interactive config surfaces.
- The rendered plans are not yet covered by golden fixtures.

## Sprint 1.8: Subprocess ADT Formalization 📋

**Status**: Planned
**Docs to update**: `documents/engineering/effect_interpreter.md`,
`documents/engineering/streaming_doctrine.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Architecture → Subprocesses as Typed
Values](../HASKELL_CLI_TOOL.md).

### Deliverables

- Refactor `src/Prodbox/Subprocess.hs` to the doctrine's `Subprocess` record
  (`subprocessPath`, `subprocessArguments`, `subprocessEnvironment`,
  `subprocessWorkingDirectory`) with pure `renderSubprocess :: Subprocess -> Text`.
- Interpreter API: `runStreaming :: Subprocess -> IO (Either AppError ExitCode)` and
  `capture :: Subprocess -> IO (Either AppError ProcessOutput)`. Forbid direct
  `System.Process` / `typed-process` smart-constructor usage outside the interpreter via a
  custom hlint rule and a `forbiddenPathRegistry` entry on the doctrine's prescribed names.
- Migrate every call site under `src/Prodbox/` that currently constructs subprocesses inline.
- Sprint 0.4 round-3 extension: name `callProcess`, `readCreateProcess`, and direct
  `System.Process` smart constructors (`createProcess`, `proc`, `shell`) explicitly
  in the `prodbox lint files` rules and the `.hlint.yaml` negative-space symbol set
  (composing with the Sprint 1.19 negative-space rules) per
  [../HASKELL_CLI_TOOL.md → Architecture → Subprocesses as Typed
  Values](../HASKELL_CLI_TOOL.md) §531. A `prodbox-haskell-style` unit test asserts
  that no module outside `src/Prodbox/Subprocess.hs` imports `System.Process` and
  that the forbidden symbols never appear in `src/Prodbox/CLI/` call sites.

### Validation

1. `cabal test prodbox-unit` covers the rendered subprocess golden tests.
2. The legacy ledger lists the migrated call sites.

## Sprint 1.9: Prerequisite Registry Remedy-Hint Contract 📋

**Status**: Planned
**Docs to update**: `documents/engineering/prerequisite_doctrine.md`,
`documents/engineering/prerequisite_dag_system.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Prerequisites as Typed
Effects](../HASKELL_CLI_TOOL.md), including the required error-message contract.

### Deliverables

- Extend `src/Prodbox/Prerequisite.hs` so every node carries `nodeDescription` and a literal
  remedy hint and so `transitiveClosure :: [Text] -> Map Text PrerequisiteNode -> Either
  AppError [PrerequisiteNode]` rejects unknown IDs at expansion time.
- Replace any remaining inline `unless toolExists`-style checks with registry nodes; queue the
  removed call sites in the legacy ledger.

### Validation

1. Every prerequisite failure surfaces `nodeId`, `nodeDescription`, and the remedy hint.
2. Unit tests cover registry-typo detection at expansion time.

## Sprint 1.10: Lint, Generated-Section, and Forbidden-Path Stack ✅

**Status**: Done
**Implementation**: `fourmolu.yaml`, `.hlint.yaml`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/CLI/Docs.hs`, `test/unit/Main.hs`, `test/haskell-style/Main.hs`
**Docs to update**: `documents/engineering/code_quality.md`,
`documents/documentation_standards.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Lint, Format, and Code-Quality
Stack](../HASKELL_CLI_TOOL.md) and `Generated Artifacts → The generated-section registry`.

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
  [../HASKELL_CLI_TOOL.md → Generated Artifacts](../HASKELL_CLI_TOOL.md) §381–390 and
  `The Architecture` §2321. `documents/engineering/cli_command_surface.md` records this
  consolidation so future contributors do not split the two surfaces.
- `prodbox lint haskell` round-trips `prodbox.cabal` through `cabal format` via a temp file
  and asserts byte-equality with the on-disk file per
  [../HASKELL_CLI_TOOL.md → Lint, Format, and Code-Quality Stack → Tool
  Bootstrap](../HASKELL_CLI_TOOL.md) §1834–1837. The check pass never rewrites in place;
  rewrite-in-place is reserved for `prodbox lint haskell --write`.
- Sprint 0.4 round-3 extension: bind the twelve minimum `fourmolu.yaml` settings
  explicitly. The repo-root `fourmolu.yaml` carries `indentation: 2`,
  `column-limit: 100`, `function-arrows: leading`, `comma-style: leading`,
  `import-export-style: leading`, `indent-wheres: false`,
  `record-brace-space: true`, `newlines-between-decls: 1`,
  `haddock-style: single-line`, `let-style: auto`, `in-style: right-align`,
  `unicode: never`, and `respectful: true`, per
  [../HASKELL_CLI_TOOL.md → Lint, Format, and Code-Quality Stack → Pinned
  fourmolu.yaml](../HASKELL_CLI_TOOL.md) §1834–1860. A `prodbox-haskell-style` unit
  test parses `fourmolu.yaml` and asserts each of the twelve keys is present with
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

## Sprint 1.11: hspec → tasty Test-Stanza Migration 🔄

**Status**: Active
**Implementation**: `prodbox.cabal`, `test/unit/Main.hs`, `test/unit/Parser.hs`, `test/integration/cli/Main.hs`, `test/integration/env/Main.hs`, `test/haskell-style/Main.hs`, `test/daemon-lifecycle/Main.hs`, `test/pulumi/Main.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Testing Doctrine](../HASKELL_CLI_TOOL.md), `Standard
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
  [../HASKELL_CLI_TOOL.md → Test Organization](../HASKELL_CLI_TOOL.md). Add a
  `prodbox lint files` (Sprint 1.10) rule that fails on any new test-suite stanza missing the
  interface.
- Enqueue the `hspec` and `hspec-discover` dependencies in the legacy ledger.
- Sprint 0.4 round-3 extension: enumerate the canonical property-test invariants
  the `prodbox-unit` stanza must cover, per
  [../HASKELL_CLI_TOOL.md → Test Categories → Property
  Tests](../HASKELL_CLI_TOOL.md) §2179–2188:
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

- The repository has already migrated off `hspec`: the current public suites are tasty-based and
  every existing test-suite stanza uses `type: exitcode-stdio-1.0`.
- `prodbox-haskell-style`, `prodbox-daemon-lifecycle`, and `prodbox-pulumi` now exist as Cabal
  stanzas, but the doctrinal single `prodbox-integration` stanza has not replaced the current
  split CLI and env suites.
- The doctrine-named property-test invariants remain only partially implemented in
  `test/unit/Main.hs`, and the deeper lifecycle or ephemeral-stack behavior owned by Sprints
  `2.14` and `4.7` is still scaffold-only in their new stanzas.

## Sprint 1.12: Capability Classes and AsServiceError 📋

**Status**: Planned
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Capability Classes and Service
Errors](../HASKELL_CLI_TOOL.md).

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
  [../HASKELL_CLI_TOOL.md → Capability Classes and Service
  Errors](../HASKELL_CLI_TOOL.md) §867–890. The inventory is the closed set on the
  supported path; any later subsystem (e.g. a future `HasNats`) adds an entry to
  the inventory rather than constructing an ad-hoc error type.

### Validation

1. `cabal test prodbox-unit` covers retry behavior using `Env` test hooks (Sprint 2.X).
2. Direct MinIO / Redis / Postgres call sites outside the capability classes are absent.

## Sprint 1.13: RetryPolicy as First-Class Values 📋

**Status**: Planned
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Retry Policy as First-Class
Values](../HASKELL_CLI_TOOL.md).

### Deliverables

- Introduce a shared `RetryPolicy` value plus pure `retryDelayMicros` calculation.
- Replace hardcoded retry constants in `src/Prodbox/CLI/Rke2.hs` (Harbor mirror fallback, Helm
  fetch retry) and any other ad-hoc retry loops with explicit `RetryPolicy` values plus
  `serviceErrorRetryable` classification.
- Enqueue removed retry constants in the legacy ledger.

### Validation

1. Property tests confirm exponential backoff for the default policy.
2. The retry surface is consumed only through the `RetryPolicy` API.

## Sprint 1.14: Recoverable / Fatal ErrorKind 📋

**Status**: Planned
**Docs to update**: `documents/engineering/haskell_code_guide.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Error handling:
recoverable vs fatal](../HASKELL_CLI_TOOL.md) and propagate the discipline across
short-running commands too.

### Deliverables

- Extend `AppError` (or its successor) with `errorKind :: ErrorKind` where
  `ErrorKind = Recoverable | Fatal`.
- Worker loops (gateway daemon, chart reconcile, lifecycle retries) classify errors at the
  call site and respond accordingly.
- Sprint 0.4 round-3 extension: bind the daemon `AppError` record shape explicitly:
  `data AppError = AppError { errorKind :: ErrorKind, errorMsg :: Text, errorCause :: Maybe SomeException }`
  per [../HASKELL_CLI_TOOL.md → Long-Running Daemons in the Same Binary → Error
  Handling](../HASKELL_CLI_TOOL.md) §1300–1340. The `errorMsg` carries the
  operator-facing summary that `renderError` (Sprint 1.26) consumes at the CLI
  boundary; `errorCause` preserves the originating exception for structured-log
  context without leaking it through the user-facing text.

### Validation

1. Unit tests cover the `Recoverable`-with-backoff path.
2. The gateway daemon and chart reconcile surface fatal errors to the supervisor without
   silently retrying.

## Sprint 1.15: Naming Helpers and Smart-Constructor Module 📋

**Status**: Planned
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Smart Constructors for Paired
Resources](../HASKELL_CLI_TOOL.md), including the prescribed naming helpers.

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
  per [../HASKELL_CLI_TOOL.md → Smart Constructors for Paired
  Resources](../HASKELL_CLI_TOOL.md) §565–630. Unit tests cover the
  63-character bound, the DNS-1123 character set, and the
  hash-suffix-prevents-collision contract.

### Validation

1. Unit tests cover the DNS-1123 length and character invariants.
2. Hand-constructed resource names outside the helper module are absent.

## Sprint 1.16: GADT-Indexed State Machines for Multi-State Workflows 📋

**Status**: Planned
**Docs to update**: `documents/engineering/haskell_code_guide.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → GADT-Indexed State Machines](../HASKELL_CLI_TOOL.md) for
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

## Sprint 1.17: Output Discipline for One-Shot CLI Commands 📋

**Status**: Planned
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Output Rules](../HASKELL_CLI_TOOL.md) for one-shot `prodbox`
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

## Sprint 1.18: One-Shot Env Record and ReaderT App Adoption 📋

**Status**: Planned
**Docs to update**: `documents/engineering/haskell_code_guide.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Application Environment](../HASKELL_CLI_TOOL.md) for the
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

## Sprint 1.19: Style-Tools Sandbox and Custom Nesting Hlint Rules 📋

**Status**: Planned
**Docs to update**: `documents/engineering/code_quality.md`,
`documents/engineering/dependency_management.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Lint, Format, and Code-Quality Stack → Tool
Bootstrap](../HASKELL_CLI_TOOL.md) and the `Readability and Nesting` subsection's
project-specific `.hlint.yaml` rule pattern.

### Deliverables

- `prodbox lint haskell` (Sprint 1.10) bootstraps `fourmolu` and `hlint` into
  `.build/prodbox-style-tools/bin/` via `ghcup run` plus `cabal install`, pinned to a
  formatter-tool GHC version declared as a single constant in `src/Prodbox/Lint.hs` (new
  module). The formatter-tool GHC is isolated from the project compiler so format output is
  reproducible across contributors and CI.
- Repo-root `.hlint.yaml` exists, committed, and lists the doctrine's nested-case warnings
  (`Refactor nested case`, `Avoid case inside lambda body`). The file is consumed by both
  `prodbox lint haskell` and the `prodbox-haskell-style` test-suite stanza (Sprint 1.11) so
  the rules accumulate over time without parallel surfaces.
- `.hlint.yaml` carries negative-space symbol rules refusing `forkIO`, `unsafePerformIO`, and
  module-level `IORef` inside `src/Prodbox/Gateway/`, `src/Prodbox/Workload.hs`, and any new
  daemon path, per
  [../HASKELL_CLI_TOOL.md → Long-Running Daemons → Structured Concurrency / Test Hooks in
  Env / The Env Record Grows](../HASKELL_CLI_TOOL.md) §1243, §1370, §1450. Production code
  uses `Control.Concurrent.Async` (`withAsync`, `concurrently`, `race`,
  `replicateConcurrently`) and threads resources through `Env`, not module-level `IORef`.
- The lint stack runs hlint with `--with-group=default` plus `--with-group=extra` per
  doctrine.
- `prodbox check-code` continues to dispatch into the same path; no parallel
  developer-tooling fourmolu invocation survives outside the doctrine-pinned sandbox.
- Enqueue host-installed `fourmolu` / `hlint` use and the absence of `.hlint.yaml` in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. `prodbox lint haskell` succeeds on a clean tree using only the sandboxed formatter
   binaries; no host-installed `fourmolu` or `hlint` is consulted.
2. Adding a deliberately nested `case` inside a lambda body fails `prodbox lint haskell`
   with the doctrine-named rule.
3. Introducing a `forkIO`, `unsafePerformIO`, or module-level `IORef` declaration inside
   any daemon-path module fails `prodbox lint haskell` with the negative-space symbol
   rule.

## Sprint 1.20: Aggregate Test and Lint Dispatch Alignment ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/TestRunner.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Lint, Format, and Code-Quality Stack → Aggregate
Dispatch](../HASKELL_CLI_TOOL.md) and the doctrine's `Testing Doctrine` requirement that
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

## Sprint 1.21: Tracked-Generated Paths Registry and Renderer Determinism 📋

**Status**: Planned
**Docs to update**: `documents/documentation_standards.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Generated Artifacts → Two Categories of
Generation](../HASKELL_CLI_TOOL.md) and the `Determinism Requirements` subsection so
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
  [../HASKELL_CLI_TOOL.md → Generated Artifacts → Renderer
  Determinism](../HASKELL_CLI_TOOL.md) §459–470:
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

## Sprint 1.22: Standardized Library Audit 📋

**Status**: Planned
**Docs to update**: `documents/engineering/dependency_management.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Standardized Stack](../HASKELL_CLI_TOOL.md) by auditing
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

## Sprint 1.23: Dhall Freeze, Daemon CLI Negative-Space Rule, and Cross-Language Generation Deferral 📋

**Status**: Planned
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/code_quality.md`, `documents/documentation_standards.md`

### Objective

Close the residual doctrine items from
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) that are not owned by an earlier sprint in
this phase: the `dhall freeze` reproducibility discipline on the committed Dhall schema
(§1571–1574), the parser `--foreground` default plus the explicit
self-daemonization-forbidden rule (§1591–1599), and the explicit deferral of cross-language
type generation (§341–343) until a non-Haskell consumer enters scope.

### Deliverables

- `prodbox-config-types.dhall` and any committed defaults file are frozen via `dhall freeze`,
  so every import carries a SHA-256 hash. `src/Prodbox/CheckCode.hs` refuses unfrozen
  imports (new doctrine-alignment scan: parse the file, walk imports, fail when any import
  is missing its `sha256:...` annotation). Operators run `dhall freeze` after intentional
  schema edits; `prodbox check-code` catches unfrozen residue.
- `src/Prodbox/CLI/Parser.hs` exposes `--foreground` as the default on every daemon-launching
  command introduced by Sprint 2.15; `src/Prodbox/Gateway/Daemon.hs` and
  `src/Prodbox/Workload.hs` refuse any double-fork or `setsid` branch. A
  `prodbox-haskell-style` unit test asserts that no daemon-path module imports
  `System.Posix.Process` `forkProcess` or invokes `setsid` directly.
- `documents/engineering/cli_command_surface.md` records the
  cross-language-types-generation deferral: the marker-delimited generation pattern
  documented by [../HASKELL_CLI_TOOL.md → Generated Artifacts](../HASKELL_CLI_TOOL.md)
  §341–343 is ready when a non-Haskell consumer (e.g. a TypeScript or Go type mirror)
  enters scope, but no such consumer exists today and no sprint schedules one. The
  `generatedSectionRule` registry stays empty for cross-language types until a future plan
  revision opens that surface.
- Enqueue the pre-doctrine unfrozen Dhall imports, the missing
  self-daemonization-forbidden assertion, and any host-installed
  `dhall freeze` workflow in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. `prodbox check-code` fails when a committed Dhall import is missing its `sha256:`
   hash.
2. Adding a `forkProcess` or `setsid` call inside `src/Prodbox/Gateway/Daemon.hs` or
   `src/Prodbox/Workload.hs` fails `prodbox-haskell-style`.
3. `documents/engineering/cli_command_surface.md` lists the cross-language-types deferral as
   an explicit doctrine-aware no-op rather than as a silent gap.

## Sprint 1.24: Durable CLI Documentation Artifacts 🔄

**Status**: Active
**Implementation**: `src/Prodbox/CLI/Docs.hs`, `src/Prodbox/CheckCode.hs`, `documents/cli/commands.md`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/documentation_standards.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Automatically Generated
Documentation](../HASKELL_CLI_TOOL.md) §269–318 and `The Architecture` summary
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
- Each artifact path is registered in the `trackingGeneratedPaths` registry
  (Sprint 1.21) so any hand edit fails `prodbox lint files` with the doctrine's
  three-element error message (path / registry key / remedy hint pointing at
  `prodbox docs generate`).
- HTML output is **deferred** as an explicit doctrine-aware no-op (same form as
  Sprint 1.23's cross-language-types deferral). The deferral is recorded in
  `documents/engineering/cli_command_surface.md` and
  `documents/documentation_standards.md` so future contributors do not silently
  reintroduce the gap.
- `prodbox docs generate` (Sprint 1.10) regenerates every artifact; the paired
  `prodbox docs check` fails on drift.
- Golden tests in `prodbox-haskell-style` (Sprint 1.11) cover each rendered
  artifact byte-for-byte against committed fixtures; the renderer-determinism
  property test (Sprint 1.21) covers every new renderer.
- Enqueue the pre-doctrine absence of durable doc artifacts in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with Sprint
  1.24 as the owning sprint.

### Validation

1. `prodbox docs generate` followed by `prodbox docs check` is a no-op on a clean
   tree.
2. Hand-editing any registered artifact fails `prodbox lint files`.
3. The renderer-determinism property test (Sprint 1.21) fails when any new
   renderer embeds a timestamp, locale-dependent ordering, or
   terminal-width-dependent wrapping.
4. `documents/engineering/cli_command_surface.md` lists the HTML deferral as an
   explicit doctrine-aware no-op rather than as a silent gap.

### Remaining Work

- `src/Prodbox/CLI/Docs.hs` now renders the Markdown command reference at
  `documents/cli/commands.md`, and `prodbox docs check|generate` already maintain that
  marker-delimited artifact through the generated-section registry.
- The doctrine-owned manpages, shell completion scripts, and `trackingGeneratedPaths`
  registration are still absent, and `prodbox-haskell-style` does not yet carry the
  byte-for-byte artifact golden coverage scheduled for this sprint.

## Sprint 1.25: Parser-Test Category via execParserPure ✅

**Status**: Done
**Implementation**: `test/unit/Main.hs`, `test/unit/Parser.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CheckCode.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Parser Tests](../HASKELL_CLI_TOOL.md) §2116–2138 so
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

## Sprint 1.26: Error Rendering Boundary Discipline 📋

**Status**: Planned
**Docs to update**: `documents/engineering/haskell_code_guide.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [../HASKELL_CLI_TOOL.md → Error Handling](../HASKELL_CLI_TOOL.md) §815–831
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
[../HASKELL_CLI_TOOL.md → Toolchain pinning](../HASKELL_CLI_TOOL.md) §70–84 and
`Project Structure` §86–115.

### Deliverables

- `prodbox.cabal` declares `tested-with: ghc ==9.14.1` at the package-stanza level
  per [../HASKELL_CLI_TOOL.md → Toolchain pinning](../HASKELL_CLI_TOOL.md) §75.
- `cabal.project` declares `with-compiler: ghc-9.14.1` per
  [../HASKELL_CLI_TOOL.md → Toolchain pinning](../HASKELL_CLI_TOOL.md) §76.
- The plan and [00-overview.md](00-overview.md) name the authoritative Cabal
  version `Cabal 3.16.1.0` per
  [../HASKELL_CLI_TOOL.md → Toolchain pinning](../HASKELL_CLI_TOOL.md) §74; the
  doctrine pins both the GHC and Cabal versions, and this sprint binds the Cabal
  pin in cabal-manifest terms alongside the existing GHC `9.14.1` references.
- `src/Prodbox/CheckCode.hs` gains a check that refuses any module-local
  definition in `app/prodbox/Main.hs` beyond a thin
  `main = Prodbox.App.main` (or equivalent library re-export) per
  [../HASKELL_CLI_TOOL.md → Project Structure](../HASKELL_CLI_TOOL.md) §103–114
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
  [../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md) pointer.
- `documents/engineering/cli_command_surface.md` - canonical Haskell command matrix, deferring
  to the doctrine for `CommandSpec`, `Command Topology`, and `Progressive Introspection`.
- `documents/engineering/code_quality.md` - Haskell `check-code` contract, deferring to the
  doctrine for `Lint, Format, and Code-Quality Stack`, `Forbidden Surfaces`, and
  `Generated Artifacts`.
- `documents/engineering/haskell_code_guide.md` - hard-gate Haskell quality doctrine and
  review-guidance split, deferring to the doctrine for GADT state machines, smart
  constructors, subprocess values, retry policy, and capability classes.
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
- `documents/engineering/prerequisite_dag_system.md` - prerequisite DAG construction and reduction.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite registry doctrine, deferring
  to the doctrine for `Prerequisites as Typed Effects`.
- `documents/engineering/streaming_doctrine.md` - terminal streaming invariants.
- `documents/engineering/unit_testing_policy.md` - Haskell unit and integration harness
  doctrine, deferring to the doctrine for the tasty stack and stanza layout.

**Product docs to create/update:**

- `README.md` - supported operator flow after the Haskell rewrite.
- `AGENTS.md` - repository guidance for the Haskell architecture.
- `CLAUDE.md` - assistant guidance aligned to the rewritten repository.

**Cross-references to add:**

- Keep Phase `1` linked from [README.md](README.md) and [00-overview.md](00-overview.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
