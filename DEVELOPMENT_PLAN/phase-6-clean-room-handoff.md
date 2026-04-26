# Phase 6: Final Clean-Room Rerun and Zero-Python Handoff

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

> **Purpose**: Capture the zero-Python handoff criteria: a full clean-room rerun through the
> Haskell stack and a cleanup ledger where any surviving supported-path residue is explicitly
> owned by its originating phase.

## Phase Summary

This phase defines the clean-room and zero-Python handoff criteria for the Haskell-only
repository. Sprint `6.1` now passes the authoritative destructive rerun on April 26, 2026.
Sprint `6.2` remains closed as well: the Phase `7` onboarding and AWS administration surfaces are
closed on Haskell-only paths, the Python artifact cleanup is complete, and the non-Python cleanup
ledger is closed again after the `ghcup` plus `ghc-9.14.1` container-path and Percona-operator
implementation work landed on April 26, 2026. This phase owns the destructive rerun contract,
the final zero-Python handoff criteria, and the dependency between those surfaces and the earlier
lifecycle, gateway, chart, and AWS phases.

## Current Baseline In Worktree

- The destructive rerun proof runs entirely through Haskell command paths. All Python source,
  Python tests, and Python toolchain have been removed from the repository.
- The frontend request path and supported-runtime helpers no longer retain Python-era delegation
  or Python-named context scaffolding inside Haskell modules.
- The `prodbox test` orchestration path runs Haskell test suites via `cabal test` and native CLI
  orchestration.
- All onboarding and AWS administration commands are Haskell-owned in `src/Prodbox/Aws.hs`.
- The legacy tracking ledger is the authoritative cleanup ledger for any remaining repository
  residue; it is now empty on the supported path.
- Root guidance now aligns with the post-cleanup Haskell-only repository state.

## Sprint 6.1: Destructive Haskell Rerun from Full Local Delete ✅

**Status**: Done
**Implementation**: `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Prove the clean-room baseline from full local cluster delete and a supported config contract that
lives only in operator-authored repository-root Dhall on the Haskell stack.

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
- `src/Prodbox/TestRunner.hs` now resyncs and reuses the canonical `./.build/prodbox` path before
  native aggregate phases begin, so `prodbox test all` remains valid even after nested Haskell
  suites refresh the operator binary.
- Validation steps `2`, `4`, and `5` close on the direct-Dhall config contract: no supported
  command materializes `prodbox-config.json`, and `prodbox config compile` is removed.
- Validation steps `7`, `9`, and `12` close honestly on the native validation harness because the
  named integration payloads in `src/Prodbox/TestPlan.hs` map to executable native Haskell
  validation flows.
- `src/Prodbox/TestPlan.hs` already defines the aggregate end-to-end lifecycle proof surface:
  `prodbox test all` and `prodbox test integration all` run the native validation set that
  includes `ValidationLifecycle` plus supported-runtime bootstrap and postflight, so no separate
  lifecycle suite is missing from the repository.
- On April 26, 2026, fresh host-side reruns passed `cabal build --builddir=.build exe:prodbox`,
  sync of `./.build/prodbox`, `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, `./.build/prodbox tla-check`,
  `./.build/prodbox dns check`, `./.build/prodbox host public-edge`, and
  `./.build/prodbox test integration aws-iam`.
- On April 26, 2026, direct live reruns passed `./.build/prodbox test integration charts-platform`,
  `./.build/prodbox charts delete vscode --yes`,
  `./.build/prodbox charts deploy vscode`, and
  `./.build/prodbox test integration charts-vscode`.
- On April 26, 2026, `./.build/prodbox pulumi eks-destroy --yes`, a fresh
  `./.build/prodbox test integration aws-eks`, and a second
  `./.build/prodbox pulumi eks-destroy --yes` passed after
  `src/Prodbox/Infra/AwsEksTestStack.hs` gained canonical unmanaged-residue purge before create
  and destroy when no saved snapshot exists.
- On April 26, 2026, the authoritative aggregate rerun `./.build/prodbox test all` passed after
  re-exercising unit, built-frontend CLI and env, supported-runtime restore, `charts-vscode`,
  `public-dns`, `dns-aws`, `aws-iam`, `aws-eks`, `pulumi`, AWS HA-RKE2 create/destroy,
  `gateway-daemon`, `gateway-pods`, `gateway-partition`, `charts-platform`, `charts-storage`, the
  destructive lifecycle proof, destructive postflight teardown, and the final supported-runtime
  restore to `CLASSIFICATION=ready-for-external-proof`.

### Remaining Work

None.

## Sprint 6.2: Zero-Python Repository Handoff ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/`, `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the rewrite with no supported-path Python artifacts left in the repository while leaving any
surviving non-Python cleanup explicitly owned by its originating phase in the legacy ledger after
the Phase `7` onboarding and AWS administration surfaces close on Haskell-only paths.

### Deliverables

- The repository handoff no longer depends on Python source files, Python packaging metadata,
  Python test runners, Python type stubs, Python Pulumi programs, or Python-owned onboarding and
  AWS administration helpers.
- The Python-removal portion of the legacy ledger is empty; any surviving non-Python compatibility
  cleanup is owned by its originating phase.
- Root guidance docs and governed doctrine no longer describe Python as the supported runtime.
- The destructive rerun closes after Python removal rather than before it.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test all`
4. Repository artifact-search proof shows that no supported-path Python files or Python toolchain
   ownership artifacts remain.
5. Repository text-search proof shows that no surviving Python-era architecture statements remain
   on the supported path.

### Current Validation State

- The supported implementation surfaces remain Haskell-only. No supported-path Python
  implementation or Python toolchain artifact survives.
- The dead Python-era `DelegateToPython` request constructor and
  `supportedRuntimePythonPath` field are removed from `app/` and `src/`, so the zero-Python
  handoff no longer depends on hidden compatibility scaffolding inside Haskell modules.
- `prodbox check-code` and `prodbox test all` remain the canonical aggregate proof surfaces.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is now empty, and the root
  guidance set named in `Docs to update` is realigned to the current repository state.
- The legacy ledger remains clear on Python-removal items.
- On April 26, 2026, fresh local reruns on the current configured checkout passed
  `cabal build --builddir=.build exe:prodbox`, sync of `./.build/prodbox`,
  `./.build/prodbox check-code`, `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, `./.build/prodbox test integration env`,
  `./.build/prodbox tla-check`, `./.build/prodbox dns check`,
  `./.build/prodbox host public-edge`, and `./.build/prodbox test integration aws-iam`.
- On April 26, 2026, a direct retained-state rerun also passed
  `./.build/prodbox charts delete vscode --yes` followed by
  `./.build/prodbox charts deploy vscode`.
- The current workspace contains repository-root `prodbox-config.dhall`.
- On April 26, 2026, the authoritative aggregate rerun `./.build/prodbox test all` passed,
  re-establishing the infrastructure-backed aggregate closure evidence for the zero-Python
  handoff on the updated lifecycle, gateway, chart, and AWS surfaces.


### Remaining Work

None.

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
