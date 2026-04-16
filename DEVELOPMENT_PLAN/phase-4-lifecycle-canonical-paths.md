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

## Sprint 4.1: Lifecycle Parity and Canonical-Path Closure on the Haskell Stack 📋

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Lib/`, `test/integration/lifecycle/`
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

### Remaining Work

- All deliverables remain open.

## Sprint 4.2: Replace Python Pulumi Programs with Non-Python Pulumi Definitions 📋

**Status**: Planned
**Implementation**: `pulumi/`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `test/integration/aws/`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`

### Objective

Retain Pulumi as the infrastructure engine while removing Python from the supported Pulumi path.

### Deliverables

- Existing Python Pulumi stack programs are replaced with non-Python Pulumi definitions.
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

### Remaining Work

- All deliverables remain open.

## Sprint 4.3: Repository-Wide Python Toolchain Removal 📋

**Status**: Planned
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `typings/`, `pyproject.toml`, `poetry.lock`, `.python-version`
**Docs to update**: `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/cli_command_surface.md`

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

### Remaining Work

- All deliverables remain open.

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
