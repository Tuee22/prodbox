# Phase 6: Final Clean-Room Rerun and Zero-Python Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the zero-Python handoff criteria: a full clean-room rerun through the
> Haskell stack and an empty remaining Python-removal ledger.

## Phase Summary

This phase reran the authoritative validation set from the supported destructive operator flow
after the Haskell runtime, gateway, chart, Pulumi, and public-host phases closed. Sprint `6.1`
re-proved the destructive operator flow on Haskell command paths. Sprint `6.2` closed after
Phase `7` onboarding and AWS administration surfaces landed on Haskell-only paths and all Python
artifacts were removed from the repository. Final plan exit now still depends on reopened Sprint
`1.2` config-contract, native-harness, and doc-harmony cleanup, but that does not reopen the
zero-Python repository surfaces owned here.

## Current Baseline In Worktree

- The destructive rerun proof runs entirely through Haskell command paths. All Python source,
  Python tests, and Python toolchain have been removed from the repository.
- The `prodbox test` orchestration path runs Haskell test suites via `cabal test` and native CLI
  orchestration. `test:prodbox-unit`, `test:prodbox-integration-cli`, and
  `test:prodbox-integration-env` pass on the April 18, 2026 worktree.
- All onboarding and AWS administration commands are Haskell-owned in `src/Prodbox/Aws.hs`.
- The legacy tracking ledger is now empty in `Pending Removal`; Python removal and the reopened
  Sprint `1.2` compatibility or doc-harmony cleanup are complete.

## Sprint 6.1: Destructive Haskell Rerun from Full Local Delete ✅

**Status**: Done
**Implementation**: `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Re-prove the clean-room baseline from full local cluster delete and a supported config contract
that lives only in repository-root Dhall on the Haskell stack.

### Deliverables

- The authoritative rerun starts from `prodbox rke2 delete --yes` and no supported-path generated
  `prodbox-config.json` artifact.
- The local cluster is rebuilt through the Haskell lifecycle path.
- The Pulumi backend is restored and both AWS-backed validation patterns rerun through Haskell
  surfaces.
- The rerun finishes at the supported public-edge and AWS-residue-free state.

### Validation

1. `prodbox rke2 delete --yes`
2. Repository artifact proof starts with no supported-path `prodbox-config.json` and no supported
   command recreates it during `prodbox config show` or `prodbox config validate`.
3. `prodbox rke2 install`
4. `prodbox config show`
5. `prodbox config validate`
6. `prodbox pulumi eks-resources`
7. `prodbox test integration aws-eks`
8. `prodbox pulumi test-resources`
9. `prodbox test integration ha-rke2-aws`
10. `prodbox pulumi eks-destroy --yes`
11. `prodbox pulumi test-destroy --yes`
12. `prodbox test all`
13. `prodbox host public-edge`

### Current Validation State

- The destructive operator flow and aggregate runner remain Haskell-only on the runtime surface.
- Validation steps `2`, `4`, and `5` close on the direct-Dhall config contract: no supported
  command materializes `prodbox-config.json`, and `prodbox config compile` is removed.
- Validation steps `7`, `9`, and `12` close honestly on the native validation harness because the
  named integration payloads in `src/Prodbox/TestPlan.hs` map to executable native Haskell
  validation flows.

### Remaining Work

None.

## Sprint 6.2: Zero-Python Repository Handoff ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/`, `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the rewrite with an empty Python-removal ledger and no supported-path Python artifacts left in the repository after the Phase `7` onboarding and AWS administration surfaces close on Haskell-only paths.

### Deliverables

- The repository handoff no longer depends on Python source files, Python packaging metadata,
  Python test runners, Python type stubs, Python Pulumi programs, or Python-owned onboarding and
  AWS administration helpers.
- The Python-removal portion of the legacy ledger is empty; any surviving non-Python compatibility
  cleanup is owned by its originating phase.
- Root guidance docs and governed doctrine no longer describe Python as the supported runtime.
- The destructive rerun remains closed after Python removal rather than before it.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test all`
4. Repository artifact-search proof shows that no supported-path Python files or Python toolchain ownership artifacts remain.
5. Repository text-search proof shows that no surviving Python-era architecture statements remain on the supported path.

### Current Validation State

- The repository filesystem remains Haskell-only. No supported-path Python implementation or
  Python toolchain artifact survives.
- `prodbox check-code` is part of today's passing local proof, and `prodbox test all` now owns a
  fully native validation harness for the named real-world proof surfaces.
- Repository text search across the root guidance docs and governed Sprint `1.2` docs is aligned
  with the Haskell-only repository and no longer depends on mixed-baseline wording.

### Remaining Work

None. All Python source, Python packaging, Python tests, Python type stubs, Python Pulumi
programs, and Python bridge modules have been removed. The repository is Haskell-only.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - final Haskell command matrix.
- `documents/engineering/README.md` - engineering index aligned to the final Haskell-only doctrine
  set.
- `documents/engineering/prerequisite_doctrine.md` - clean-room rerun prerequisites on the Haskell
  stack.
- `documents/engineering/storage_lifecycle_doctrine.md` - final lifecycle and retained-root
  contract.
- `documents/engineering/unit_testing_policy.md` - aggregate validation doctrine after Python
  removal.
- `documents/engineering/dependency_management.md` - final non-Python build and dependency posture.

**Product docs to create/update:**

- `README.md` - supported operator flow after the Haskell rewrite.
- `AGENTS.md` - repository guidance for the Haskell architecture.
- `CLAUDE.md` - assistant guidance aligned to the rewritten repository.

**Cross-references to add:**

- Keep the final handoff criteria linked to
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
