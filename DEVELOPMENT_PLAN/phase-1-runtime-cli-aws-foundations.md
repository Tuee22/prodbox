# Phase 1: Haskell Runtime, CLI, Config, and Pulumi Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell runtime, CLI, configuration, build, and Pulumi foundations that
> make later gateway, chart, and public-host phases meaningful and testable.

## Phase Summary

This phase establishes the Haskell `prodbox` binary, the canonical Cabal build topology, the
repository-root Dhall config loader, the Haskell command runtime and test harness, and the Pulumi
foundations for local infrastructure plus AWS validation. Sprint `1.2` remains closed on the
direct-Dhall config contract, native validation harness, and doc harmony. Sprint `1.1` is now
closed on this host as well: the canonical frontend image build lives at
`docker/prodbox.Dockerfile`, the custom-image doctrine is aligned on single-stage `ubuntu:24.04`
under `docker/`, the Haskell toolchain is mounted from the official `haskell:9.6.7-slim` image
at build time while keeping the final image single-stage, the owning docs are updated, and the
canonical host-side validation commands pass again after restoring the ncurses development linker
dependency.

## Current Baseline In Worktree

- The Haskell `prodbox` binary is the sole CLI owner. All Python source, Python packaging, and
  Python bridge modules have been removed from the repository.
- The supported Haskell config surface is `setup|show|validate`; `config compile` is removed. The
  rest of the supported command matrix remains Haskell-owned:
  `aws policy|setup|teardown|check-quotas|request-quotas`,
  `host ensure-tools|check-ports|info|firewall|public-edge`, `rke2`, `pulumi`, `dns check`,
  `gateway start|status|config-gen`, `charts`, `k8s health|wait|logs`, `check-code`, `test`, and
  `tla-check`.
- Repository-root config artifacts are `prodbox-config.dhall` and `prodbox-config-types.dhall`;
  `src/Prodbox/Settings.hs` owns decoding, display, and validation without materializing
  `prodbox-config.json`.
- The host build contract copies the operator-facing binary to `.build/prodbox` after the
  canonical `cabal build --builddir=.build exe:prodbox` invocation.
- The canonical frontend container build now lives at `docker/prodbox.Dockerfile`.
- `docker/prodbox.Dockerfile` is a single-stage `ubuntu:24.04` build that preserves the
  `/opt/build` artifact contract and mounts the official `haskell:9.6.7-slim` image as a
  BuildKit toolchain context during publication.
- `test/integration/env/Main.hs` proves built-frontend config masking and validation directly
  against repository-root Dhall config without recreating `prodbox-config.json`.
- Named external-proof payloads behind `prodbox test integration ...` run executable native
  Haskell validation flows through `src/Prodbox/TestValidation.hs`.
- All Pulumi programs are YAML-based under `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`,
  and `pulumi/aws-test/Main.yaml`.
- The canonical host-side validation reruns now pass on this host:
  `cabal build --builddir=.build exe:prodbox`,
  `cabal run --builddir=.build exe:prodbox -- check-code`,
  `./.build/prodbox check-code`,
  `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`,
  and `./.build/prodbox test integration env`.

## Sprint 1.1: Haskell Binary, Build Topology, and Command Surface ✅

**Status**: Done
**Implementation**: `app/prodbox/Main.hs`, `src/Prodbox/CLI/`, `src/Prodbox/Native.hs`, `prodbox.cabal`, `cabal.project`, `docker/prodbox.Dockerfile`, `docker/`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/local_registry_pipeline.md`

### Objective

Replace the Python entrypoints with one compiled Haskell `prodbox` binary and one explicit build
artifact plus container-build topology contract.

### Deliverables

- `app/prodbox/Main.hs` exists as the Haskell CLI entrypoint.
- The canonical host build invocation routes host build artifacts to `.build/` and copies the
  binary to `.build/prodbox` so operators run `./.build/prodbox`.
- The only supported home for repository-owned Dockerfiles is `docker/`.
- The custom Haskell frontend image is single-stage from `ubuntu:24.04` and still emits artifacts
  under `/opt/build`.
- The public command surface remains `prodbox` and preserves the full supported command matrix from
  [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md).

### Validation

1. `prodbox check-code`
2. `prodbox test integration cli`
3. Host build proof: the canonical Cabal build emits the binary at `.build/prodbox`, runnable as
   `./.build/prodbox`
4. Container build proof: the canonical frontend Dockerfile under `docker/` emits artifacts under
   `/opt/build`
5. Repository path proof: no supported root-level `Dockerfile` remains

### Current Validation State

- The host build contract is implemented through `cabal build --builddir=.build exe:prodbox` plus
  the `.build/prodbox` copy step in `src/Prodbox/BuildSupport.hs`.
- `docker/prodbox.Dockerfile` is the canonical frontend image definition, lives under `docker/`,
  and is single-stage `ubuntu:24.04` while preserving `/opt/build` through the mounted
  `haskell:9.6.7-slim` toolchain context.
- `test/unit/Main.hs` and `test/integration/cli/Main.hs` now assert the `docker/prodbox.Dockerfile`
  location and the updated container-build doctrine.
- Root guidance docs and the governed docs listed in `Docs to update` are aligned with the
  canonical Dockerfile location.
- `cabal build --builddir=.build exe:prodbox`,
  `cabal run --builddir=.build exe:prodbox -- check-code`,
  `./.build/prodbox check-code`,
  and `./.build/prodbox test integration cli` now pass on this host.

### Remaining Work

None.

## Sprint 1.2: Dhall Settings, Command ADTs, and Haskell Test Harness ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Native.hs`, `src/Prodbox/Repo.hs`, `test/unit/`, `test/integration/cli/`, `test/integration/env/`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/effect_interpreter.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/prerequisite_dag_system.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/streaming_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Re-express the current settings, interpreter, subprocess, and test contracts as Haskell-owned
modules.

### Deliverables

- `prodbox-config.dhall` is decoded natively from Haskell into typed settings values.
- The shared Dhall schema in `prodbox-config-types.dhall` remains aligned with the Haskell
  decoder.
- No supported command or validation path materializes `prodbox-config.json`.
- The supported `prodbox config` surface is `setup|show|validate`; `config compile` is removed.
- The current command, effect, and result contracts are represented as Haskell ADTs.
- The Haskell-owned `prodbox host ensure-tools|check-ports|info|firewall`, `prodbox k8s
  health|wait|logs`, `prodbox test`, and `prodbox check-code` command frameworks are implemented
  on a Haskell-owned entry surface.
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

- `src/Prodbox/Settings.hs` decodes `prodbox-config.dhall`, validates the required config
  contract, and renders masked `prodbox config show` output without materializing
  `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs` owns the shared `.build/support` linker shim and the
  operator-facing binary sync to `.build/prodbox`.
- `src/Prodbox/CheckCode.hs` owns `prodbox check-code` and runs
  `cabal build --builddir=.build all`, then syncs the built executable to `.build/prodbox`.
- `src/Prodbox/TestRunner.hs` owns `prodbox test ...`; it runs Haskell suites via `cabal test`,
  drives phase banners plus prerequisite and runbook gating through native
  `src/Prodbox/Effect*.hs`, `src/Prodbox/Prerequisite.hs`, and `src/Prodbox/SupportedRuntime.hs`,
  and executes the named real-world validations through `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/Host.hs` and `src/Prodbox/K8s.hs` own the public `prodbox host
  ensure-tools|check-ports|info|firewall` and `prodbox k8s health|wait|logs` paths through the
  native Haskell prerequisite, effect, DAG, interpreter, and subprocess runtime.
- `src/Prodbox/Prerequisite.hs` owns the native prerequisite inventory used by the supported test
  harness, including `tool_curl`, `tool_dig`, AWS access, Pulumi login, kubeconfig-home, and the
  cluster-backed readiness roots used by the named validation flows.
- `test/integration/cli/Main.hs` and `test/integration/env/Main.hs` remain the built-frontend
  proof surfaces for the Haskell-owned command surface.
- Root guidance docs and the governed docs listed in `Docs to update` describe the Haskell-only
  repository and current validation harness.
- The direct-Dhall settings contract, native harness, and doc-harmony surfaces owned by this
  sprint remain intact, and the canonical host-side reruns now pass on this host.

### Remaining Work

None.

## Sprint 1.3: Local Lifecycle and AWS Validation Foundations on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestRunner.hs`, `pulumi/`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Move the local lifecycle surface and both AWS-backed validation paths to Haskell while retaining
the same supported product scope.

### Deliverables

- `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` are implemented in Haskell.
- `prodbox pulumi test-resources|test-destroy --yes` and
  `prodbox pulumi eks-resources|eks-destroy --yes` are implemented in Haskell.
- The local-cluster-first MinIO backend doctrine is preserved.
- The Harbor bootstrap and registry baseline exist in Haskell and carry forward into the later
  Harbor-only dual-arch doctrine.
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

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` and `src/Prodbox/CLI/Pulumi.hs` own the public Haskell parser and
  runtime surfaces for `prodbox rke2 ...` and `prodbox pulumi ...`.
- `src/Prodbox/TestRunner.hs` aggregate bootstrap and postflight invoke native Haskell
  `prodbox rke2`, `prodbox pulumi`, and `prodbox charts` surfaces.
- `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, and
  `src/Prodbox/Infra/AwsEksTestStack.hs` own the native AWS validation-stack orchestration.
- `src/Prodbox/TestValidation.hs` provides the named lifecycle, Pulumi, EKS, and HA-RKE2 AWS
  validation flows used by `prodbox test integration ...`.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/README.md` - Haskell-only doctrine index.
- `documents/engineering/cli_command_surface.md` - canonical Haskell command matrix.
- `documents/engineering/code_quality.md` - Haskell `check-code` contract.
- `documents/engineering/dependency_management.md` - non-Python build and dependency posture,
  including the canonical Dockerfile location and base-image doctrine.
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
