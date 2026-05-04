# Phase 1: Haskell Runtime, CLI, Config, and Pulumi Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md)

> **Purpose**: Capture the Haskell runtime, CLI, configuration, build, and Pulumi foundations that
> make later gateway, chart, and public-host phases meaningful and testable.

## Phase Summary

This phase establishes the Haskell `prodbox` binary, the canonical Cabal build topology, the
repository-root Dhall config loader, the Haskell command runtime and test harness, and the Pulumi
foundations for true IaC plus AWS validation. It also owns the canonical frontend image placement
under `docker/`, the direct-Dhall config contract, the native validation harness, and the aligned
root guidance or engineering docs listed by its sprints. Later retirement of local-cluster
Pulumi ownership is Phase `4` work, not a change to the foundations closed here. Sprints `1.1`,
`1.2`, `1.3`, `1.4`, and `1.5` remain closed on the Haskell-only rewrite baseline. The phase now
closes on the single-host public-edge config doctrine: one canonical public hostname,
`test.resolvefintech.com`, settings-backed MetalLB L2 or BGP rendering, explicit public-edge
scaling inputs, and Route 53 hosted-zone alignment enforced during supported config authoring. The
implemented frontend container doctrine uses
`ubuntu:24.04` with in-image `ghcup`, pinned GHC `9.14.1`, no symlinked Haskell tool shims, and
explicit repo package-bound updates.

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
  `gateway start|status|config-gen`, `charts`, `k8s health|wait|logs`, `check-code`, `test`, and
  `tla-check`.
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
**Implementation**: `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestRunner.hs`, `pulumi/`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the local lifecycle surface and both AWS-backed validation paths on Haskell while preserving
the supported product scope.

### Deliverables

- `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` are implemented in Haskell.
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
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `pulumi/`, `test/`
**Docs to update**: `README.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the lifecycle, config-foundation, and validation-entry surfaces on the self-managed public
edge baseline: MetalLB + Envoy Gateway + Gateway API before the later single-host doctrine
extended that baseline.

### Deliverables

- `prodbox rke2 install` targets Envoy Gateway as the self-managed public-edge controller.
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
6. Self-managed edge proof: `prodbox rke2 install` reconciles MetalLB, Envoy Gateway,
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
- `prodbox rke2 install` supports config-selected MetalLB L2 or BGP rendering on the supported
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
  and the shared public-edge workload image during `prodbox rke2 install`.
- `src/Prodbox/Aws.hs` now validates Route 53 hosted-zone alignment for the canonical hostname
  during `prodbox config setup`, while `src/Prodbox/TestValidation.hs` and the built-frontend
  suites align the config and lifecycle proofs with the one-host doctrine.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` now pass from the updated tree with the single-host settings
  contract in place.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/README.md` - Haskell-only doctrine index.
- `documents/engineering/cli_command_surface.md` - canonical Haskell command matrix.
- `documents/engineering/code_quality.md` - Haskell `check-code` contract.
- `documents/engineering/haskell_code_guide.md` - hard-gate Haskell quality doctrine and
  review-guidance split.
- `documents/engineering/dependency_management.md` - non-Python build and dependency posture,
  including the canonical Dockerfile location, `ghcup` toolchain pin, and no-symlink doctrine.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Envoy Gateway and Gateway API
  public-edge doctrine.
- `documents/engineering/effect_interpreter.md` - Haskell interpreter contract.
- `documents/engineering/effectful_dag_architecture.md` - Haskell DAG model and layering.
- `documents/engineering/integration_fixture_doctrine.md` - integration setup and cleanup doctrine.
- `documents/engineering/local_registry_pipeline.md` - frontend-image location and Harbor-first
  registry expectations.
- `documents/engineering/prerequisite_dag_system.md` - prerequisite DAG construction and reduction.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite registry doctrine.
- `documents/engineering/streaming_doctrine.md` - terminal streaming invariants.
- `documents/engineering/unit_testing_policy.md` - Haskell unit and integration harness doctrine.

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
