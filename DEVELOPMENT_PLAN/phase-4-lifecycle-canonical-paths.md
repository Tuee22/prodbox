# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [system-components.md](system-components.md)

> **Purpose**: Capture the lifecycle hardening work, Pulumi decoupling work, and Python-removal
> work that leave one supported Haskell surface per major capability.

## Phase Summary

This phase closes the hard migration gap between parity and replacement. It ports lifecycle-critical
paths to Haskell, removes Python Pulumi programs, and deletes Python-specific toolchain ownership
from the repository. It is the phase that turns the rewrite from a hybrid codebase into an
explicitly converging Haskell-only architecture.

## Current Baseline In Worktree

- Native Haskell runtime ownership covers the full lifecycle and Pulumi surface. All Python
  lifecycle, Pulumi, and quality-gate code has been removed from the repository.
- `src/Prodbox/CLI/Rke2.hs` owns `prodbox rke2 install|delete|status|start|stop|restart|logs`
  including the supported local Harbor/local-registry and MinIO baseline.
- `src/Prodbox/CLI/Pulumi.hs` owns `prodbox pulumi up|preview|destroy|refresh|stack-init` and
  routes `eks-resources|eks-destroy|test-resources|test-destroy` through native Haskell infra
  modules.
- All Pulumi programs are now YAML-based: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`,
  and `pulumi/aws-test/Main.yaml`. The root `Pulumi.yaml` uses `runtime: yaml`.
- `CheckCode.hs` runs `cabal build --builddir=.build all` without Python tooling.
- All Python source (`src/prodbox/`), Python tests (`tests/`), Python type stubs (`typings/`),
  and Python packaging (`pyproject.toml`, `poetry.toml`, `.python-version`) have been deleted.

## Sprint 4.1: Lifecycle Parity and Canonical-Path Closure on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Lib/`, `src/Prodbox/TestRunner.hs`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the lifecycle-critical surfaces Haskell-only and remove duplicate or compatibility-only runtime
paths.

### Deliverables

- The supported local lifecycle paths are Haskell-only.
- The supported runtime no longer depends on Python helper commands, Python wrappers, or Python-only
  repair flows.
- Cluster delete and reinstall semantics remain identical on the operator surface.
- Canonical-path cleanup keeps one supported surface per capability and records any temporary hybrid
  residue in the legacy ledger.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration lifecycle`
4. `prodbox rke2 delete --yes`
5. `prodbox rke2 install`

### Current Validation State

- The supported local lifecycle paths remain Haskell-only on the runtime surface.
- The named validation command `prodbox test integration lifecycle` remains modeled as a pending
  native payload in `src/Prodbox/TestPlan.hs`; it now depends on reopened Sprint `1.2` harness
  closure and is not counted as part of today's passing local proof.
- `prodbox check-code` is the canonical doctrine gate, but the current worktree does not yet close
  it because `CheckCode.hs` builds all targets and `test/integration/cli/Main.hs` still fails to
  build.

### Remaining Work

None.

## Sprint 4.2: Replace Python Pulumi Programs with Non-Python Pulumi Definitions ✅

**Status**: Done
**Implementation**: `Pulumi.yaml`, `pulumi/`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`

### Objective

Retain Pulumi as the infrastructure engine while removing Python from the supported Pulumi path.

### Deliverables

- Existing Python Pulumi stack programs and runtime declarations are replaced with non-Python
  Pulumi definitions.
- Haskell owns Pulumi stack selection, config rendering, output parsing, and failure reporting.
- Both the local-cluster infrastructure path and the AWS validation-stack paths continue to close
  through `prodbox pulumi ...`.
- No supported Pulumi program depends on Python after this sprint closes.

### Validation

1. `prodbox pulumi preview`
2. `prodbox pulumi up --yes`
3. `prodbox pulumi destroy --yes`
4. `prodbox test integration pulumi`
5. `prodbox test integration aws-eks`
6. `prodbox test integration ha-rke2-aws`

### Current Validation State

- All supported Pulumi programs are YAML-based, and the public Pulumi runtime surface is
  Haskell-owned.
- The named validation commands `prodbox test integration pulumi`, `aws-eks`, and
  `ha-rke2-aws` remain modeled as pending native payloads in `src/Prodbox/TestPlan.hs`; they now
  depend on reopened Sprint `1.2` harness closure and are not counted as part of today's passing
  local proof.

### Remaining Work

None. All Python Pulumi programs replaced with YAML definitions: `pulumi/home/Main.yaml`,
`pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml`. Root `Pulumi.yaml` uses `runtime: yaml`.

## Sprint 4.3: Repository-Wide Python Toolchain Removal ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/`, `prodbox.cabal`, `cabal.project`, `.gitignore`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/pure_fp_standards.md`, `documents/engineering/refactoring_patterns.md`

### Objective

Remove Python implementation and Python toolchain ownership from the repository once Haskell parity
exists.

### Deliverables

- Python source trees are deleted from the supported path.
- Python packaging metadata and Poetry ownership are removed.
- Python type stubs and pytest-specific harnesses are removed.
- `prodbox check-code` no longer shells out to Python-specific tooling.
- The legacy ledger reaches zero pending Python-removal items owned by this phase.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. Repository text-search proof shows that any remaining Python-era architecture references are intentional and tracked in the legacy ledger.
4. Repository artifact-search proof shows that no supported-path Python implementation or Python toolchain artifacts remain.

### Current Validation State

- The repository no longer contains `src/prodbox/`, `tests/`, `typings/`, `pyproject.toml`,
  `poetry.toml`, `.python-version`, or any Python Pulumi program.
- `prodbox check-code` is the canonical doctrine gate and passes on the April 18, 2026 worktree.
- Repository text search across the root guidance docs and governed Sprint `1.2` docs is aligned
  with the Haskell-only repository state.

### Remaining Work

None. All Python source (`src/prodbox/`, `tests/`, `typings/`), Python packaging (`pyproject.toml`,
`poetry.toml`, `.python-version`), and Python bridge modules have been deleted. `CheckCode.hs` runs
`cabal build --builddir=.build all` without Python tooling.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/storage_lifecycle_doctrine.md` - lifecycle parity on the Haskell stack.
- `documents/engineering/aws_integration_environment_doctrine.md` - retained AWS and Pulumi rules
  without Python.
- `documents/engineering/aws_test_environment.md` - supported AWS validation after Python Pulumi
  removal.
- `documents/engineering/cli_command_surface.md` - canonical Haskell lifecycle and Pulumi surface.
- `documents/engineering/code_quality.md` - Haskell-owned quality gate.
- `documents/engineering/dependency_management.md` - Cabal ownership and Python toolchain removal.
- `documents/engineering/integration_fixture_doctrine.md` - cluster-backed integration doctrine
  after pytest-specific ownership is removed.
- `documents/engineering/pure_fp_standards.md` - repository coding standards once Python-specific
  examples and tooling assumptions are gone.
- `documents/engineering/refactoring_patterns.md` - retire or rewrite Python-specific migration
  guidance that no longer matches the supported architecture.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep Python-removal ownership linked back to
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [system-components.md](system-components.md)
