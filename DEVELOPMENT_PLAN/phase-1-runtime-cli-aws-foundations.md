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

## Sprint 1.1: Haskell Binary, Build Topology, and Command Surface 📋

**Status**: Planned
**Implementation**: `app/prodbox/Main.hs`, `src/Prodbox/CLI/`, `prodbox.cabal`, `cabal.project`, `docker/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`

### Objective

Replace the Python entrypoints with one compiled Haskell `prodbox` binary and one explicit build
artifact contract.

### Deliverables

- `app/prodbox/Main.hs` exists as the Haskell CLI entrypoint.
- `cabal.project` explicitly routes host build artifacts to `.build/`.
- The Dockerfile explicitly builds under `/opt/build` for containerized builds.
- The public command surface remains `prodbox` and preserves the supported command matrix.

### Validation

1. `prodbox check-code`
2. `prodbox test integration cli`
3. Host build proof: the configured Cabal build emits the binary under `.build/`
4. Container build proof: the Dockerfile build emits artifacts under `/opt/build`

### Remaining Work

- All deliverables remain open.

## Sprint 1.2: Dhall Settings, Command ADTs, and Haskell Test Harness 📋

**Status**: Planned
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/Lib/`, `src/Prodbox/CLI/`, `test/unit/`, `test/integration/`
**Docs to update**: `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`, `documents/engineering/dependency_management.md`

### Objective

Re-express the current settings, interpreter, subprocess, and test contracts as Haskell-owned
modules.

### Deliverables

- `prodbox-config.dhall` is decoded natively from Haskell.
- Materialization of `prodbox-config.json` remains available when downstream tools require it.
- The current command, effect, and result contracts are represented as Haskell ADTs.
- `prodbox test unit`, `prodbox test integration ...`, and `prodbox check-code` are implemented on
  a Haskell-native stack.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration env`

### Remaining Work

- All deliverables remain open.

## Sprint 1.3: Local Lifecycle and AWS Validation Foundations on the Haskell Stack 📋

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/`, `test/integration/lifecycle/`, `test/integration/aws/`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Move the local lifecycle surface and both AWS-backed validation paths to Haskell while retaining the
same supported product scope.

### Deliverables

- `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` are implemented in Haskell.
- `prodbox pulumi test-resources|test-destroy --yes` and `prodbox pulumi eks-resources|eks-destroy --yes` are implemented in Haskell.
- The local-cluster-first MinIO backend doctrine is preserved.
- Both intended AWS-backed validation branches survive the rewrite: EKS-backed and HA RKE2 over
  SSH.

### Validation

1. `prodbox test integration lifecycle`
2. `prodbox pulumi test-resources`
3. `prodbox pulumi test-destroy --yes`
4. `prodbox pulumi eks-resources`
5. `prodbox pulumi eks-destroy --yes`
6. `prodbox test integration aws-eks`
7. `prodbox test integration ha-rke2-aws`

### Remaining Work

- All deliverables remain open.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell command matrix.
- `documents/engineering/dependency_management.md` - Cabal build ownership and `.build/` doctrine.
- `documents/engineering/prerequisite_doctrine.md` - supported-host and tool prerequisites for the
  Haskell runtime.
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
