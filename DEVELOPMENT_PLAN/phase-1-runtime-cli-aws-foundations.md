# Phase 1: Haskell Runtime, CLI, Config, and Pulumi Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the Haskell runtime, CLI, configuration, build, and Pulumi foundations that
> make later gateway, chart, and public-host phases meaningful and testable.

## Phase Summary

This phase establishes the Haskell `prodbox` binary, the canonical Cabal build topology, the
repository-root Dhall config loader, the Haskell command runtime and test harness, and the retained
Pulumi bridge for local infrastructure plus AWS validation. It closes only when the Haskell stack
owns the local RKE2 lifecycle and both intended AWS-backed validation patterns.

## Current Baseline In Worktree

- The Haskell `prodbox` binary is the sole CLI owner. All Python source, Python packaging, and
  Python bridge modules have been removed from the repository.
- The Haskell command surface owns the full supported command matrix: `config
  compile|setup|show|validate`, `aws policy|setup|teardown|check-quotas|request-quotas`,
  `host ensure-tools|check-ports|info|firewall|public-edge`, `rke2`, `pulumi`, `dns check`,
  `gateway start|status|config-gen`, `charts`, `k8s health|wait|logs`, `check-code`, `test`, and
  `tla-check`.
- Repository-root config artifacts exist in `prodbox-config.dhall`, `prodbox-config-types.dhall`,
  and `prodbox-config.json`; `src/Prodbox/Settings.hs` owns decoding, materialization, display,
  and validation.
- All Pulumi programs are YAML-based under `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`,
  and `pulumi/aws-test/Main.yaml`.
- All 48 unit tests and 14 CLI integration tests pass.

## Sprint 1.1: Haskell Binary, Build Topology, and Command Surface ✅

**Status**: Done
**Implementation**: `app/prodbox/Main.hs`, `src/Prodbox/CLI/`, `src/Prodbox/Backend/`, `prodbox.cabal`, `cabal.project`, `Dockerfile`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`

### Objective

Replace the Python entrypoints with one compiled Haskell `prodbox` binary and one explicit build
artifact contract.

### Deliverables

- `app/prodbox/Main.hs` exists as the Haskell CLI entrypoint.
- The canonical host build invocation routes host build artifacts to `.build/`.
- The Dockerfile explicitly builds under `/opt/build` for containerized builds.
- The public command surface remains `prodbox` and preserves the full supported command matrix from
  [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md),
  including `host info|check-ports|firewall`, `k8s logs`, and
  `pulumi up|destroy|preview|refresh|stack-init`.

### Validation

1. `prodbox check-code`
2. `prodbox test integration cli`
3. Host build proof: the canonical Cabal build emits the binary under `.build/`
4. Container build proof: the Dockerfile build emits artifacts under `/opt/build`

### Current Validation State

- `cabal build --builddir=.build exe:prodbox` passes and links the Haskell binary under `.build/`.
- `cabal list-bin --builddir=.build exe:prodbox` returns a binary path under `.build/.../prodbox`.
- The built Haskell binary succeeds for `--help` and all native command surfaces.
- `docker build -t prodbox-hs-proof .` passes and builds the binary under `/opt/build`.
- `prodbox test integration cli` passes with automated proof that builds the Haskell frontend and
  exercises `--help`, native `aws policy --tier full`, native `config setup`, native
  `aws setup|teardown`, and native quota flows against a fake AWS CLI.
- The scaffold proof lives in the native Haskell unit suite `test/unit/Main.hs` plus the
  Haskell CLI integration suite `test/integration/cli/Main.hs` and env integration suite
  `test/integration/env/Main.hs`.
- `cabal.project` stays free of unsupported `builddir:` fields; the `.build/` contract is
  owned by the canonical `cabal build --builddir=.build exe:prodbox` invocation.

### Remaining Work

None.

## Sprint 1.2: Dhall Settings, Command ADTs, and Haskell Test Harness ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Native.hs`, `src/Prodbox/PythonEnv.hs`, `src/Prodbox/Repo.hs`, `test/unit/`, `test/integration/cli/`, `test/integration/env/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/effect_interpreter.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/prerequisite_dag_system.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/streaming_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Re-express the current settings, interpreter, subprocess, and test contracts as Haskell-owned
modules.

### Deliverables

- `prodbox-config.dhall` is decoded natively from Haskell.
- The shared Dhall schema in `prodbox-config-types.dhall` remains aligned with the Haskell
  decoder.
- Materialization of `prodbox-config.json` remains available when downstream tools require it.
- The current command, effect, and result contracts are represented as Haskell ADTs.
- The Haskell-owned `prodbox host ensure-tools|check-ports|info|firewall`, `prodbox k8s
  health|wait|logs`, and `prodbox test` command frameworks, plus `prodbox check-code`, are
  implemented on a Haskell-owned entry surface while deeper runtime ports remain open.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`

### Current Validation State

- `src/Prodbox/Settings.hs` decodes `prodbox-config.dhall`, materializes `prodbox-config.json`,
  validates the required config contract, and renders masked `prodbox config show` output.
- `src/Prodbox/CheckCode.hs` owns `prodbox check-code` and runs
  `cabal build --builddir=.build all`.
- `src/Prodbox/TestRunner.hs` owns `prodbox test ...`; it runs Haskell suites via `cabal test`,
  drives phase banners plus prerequisite/runbook gating for named suites through native
  `src/Prodbox/Effect*.hs`, `src/Prodbox/Prerequisite.hs`, and `src/Prodbox/SupportedRuntime.hs`,
  and owns aggregate suite ordering, aggregate coverage fan-out, and supported-runtime
  bootstrap/postflight sequencing.
- `src/Prodbox/Host.hs` and `src/Prodbox/K8s.hs` own the public `prodbox host
  ensure-tools|check-ports|info|firewall` and `prodbox k8s health|wait|logs` paths through the
  native Haskell prerequisite, effect, DAG, interpreter, and subprocess runtime.
- `src/Prodbox/Prerequisite.hs` mirrors the full shared 30-node prerequisite inventory, including
  machine identity, AWS or Route 53 access, Pulumi login, kubeconfig-home, and composite readiness
  roots; `test/unit/Main.hs` proves completeness, dependency closure, cycle freedom, and
  effect-shape parity.
- `test/integration/env/Main.hs` proves built-frontend `config show|validate` masking, failure,
  and JSON materialization behavior directly against repository-root Dhall config.
- `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/CLI/Charts.hs`, and
  `src/Prodbox/Gateway.hs` own the public Haskell entry surfaces for those command families.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` all pass. 48 unit tests and 14 CLI integration tests pass.

### Remaining Work

None.

## Sprint 1.3: Local Lifecycle and AWS Validation Foundations on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/`, `pulumi/`, `test/integration/lifecycle/`, `test/integration/aws/`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Move the local lifecycle surface and both AWS-backed validation paths to Haskell while retaining the
same supported product scope.

### Deliverables

- `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` are implemented in Haskell.
- `prodbox pulumi test-resources|test-destroy --yes` and `prodbox pulumi eks-resources|eks-destroy --yes` are implemented in Haskell.
- The local-cluster-first MinIO backend doctrine is preserved.
- The current Harbor/local-registry pipeline remains part of the lifecycle baseline unless a later
  plan change removes it explicitly.
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

- `src/Prodbox/CLI/Rke2.hs` and `src/Prodbox/CLI/Pulumi.hs` now own the public Haskell parser and
  runtime surfaces for `prodbox rke2 ...` and `prodbox pulumi ...`.
- `src/Prodbox/TestRunner.hs` aggregate bootstrap and postflight now invoke native Haskell
  `prodbox rke2`, `prodbox pulumi`, and `prodbox charts` surfaces instead of calling retained
  backend command groups directly.
- `src/Prodbox/CLI/Rke2.hs` now executes `prodbox rke2 install|delete|status|start|stop|restart|logs`
  directly through native Haskell lifecycle orchestration, including supported-host install or
  reconcile, kubeconfig sync, manual StorageClass reset, local storage or MinIO or Harbor
  bootstrap, Docker Hub mirror or image push behavior, and prodbox annotation reconciliation;
  `rke2 delete --yes` now uses native Haskell Pulumi destroy instead of Python backend delegation.
- `src/Prodbox/CLI/Pulumi.hs` now executes `prodbox pulumi up|preview|destroy|refresh|stack-init`
  through native Haskell Pulumi login, stack-selection, repo-local backend orchestration, and
  post-apply identity or annotation reconciliation. `pulumi eks-resources|eks-destroy|test-resources|test-destroy`
  now route through native Haskell modules `src/Prodbox/Infra/AwsEksTestStack.hs` and
  `src/Prodbox/Infra/AwsTestStack.hs` instead of delegating to the retained Python backend.
- `src/Prodbox/Infra/MinioBackend.hs` now owns MinIO port-forward, credentials, and bucket
  management for the local-cluster-first Pulumi backend doctrine.
- `src/Prodbox/Infra/AwsTestStack.hs` now owns HA-RKE2 AWS test stack orchestration, including
  snapshot management, provision, destroy, and residue checks.
- `src/Prodbox/Infra/AwsEksTestStack.hs` now owns EKS AWS test stack orchestration, including
  snapshot management, provision, destroy, and residue checks.
- `test/integration/cli/Main.hs` now proves fake `systemctl` / `journalctl` coverage for native
  `rke2`, fake host / `kubectl` / `helm` / `docker` / `ctr` coverage for native lifecycle install
  or delete, fake `pulumi` coverage for native home-stack Pulumi orchestration, and native Pulumi
  AWS-validation coverage through the Haskell infra modules. 48 unit tests pass, 14 CLI
  integration tests pass, and 6 env integration tests pass on the April 17, 2026 worktree.
- All commands execute through native Haskell modules. All Python Pulumi stack programs have been
  replaced with YAML Pulumi definitions under `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`,
  and `pulumi/aws-test/Main.yaml`. All 48 unit tests and 14 CLI integration tests pass.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell command matrix.
- `documents/engineering/code_quality.md` - Haskell-owned `check-code` entrypoint and doctrine
  gate.
- `documents/engineering/dependency_management.md` - Cabal build ownership and `.build/` doctrine.
- `documents/engineering/effect_interpreter.md` - Haskell runtime execution contract.
- `documents/engineering/effectful_dag_architecture.md` - Haskell command, effect, and DAG
  architecture.
- `documents/engineering/integration_fixture_doctrine.md` - non-Python cluster-backed integration
  harness doctrine.
- `documents/engineering/local_registry_pipeline.md` - Harbor or local-registry ownership retained
  by the rewritten lifecycle path.
- `documents/engineering/prerequisite_doctrine.md` - supported-host and tool prerequisites for the
  Haskell runtime.
- `documents/engineering/prerequisite_dag_system.md` - Haskell prerequisite graph construction and
  execution model.
- `documents/engineering/streaming_doctrine.md` - Haskell streaming and terminal-record contract.
- `documents/engineering/unit_testing_policy.md` - Haskell test harness and validation ownership.
- `documents/engineering/aws_integration_environment_doctrine.md` - retained AWS validation rules
  without Python.
- `documents/engineering/aws_test_environment.md` - AWS-backed EKS and HA RKE2 test-stack doctrine.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the Haskell runtime and Cabal build topology.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
