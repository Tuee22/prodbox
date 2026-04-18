# Claude Code Patterns for Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/documentation_standards.md, documents/engineering/dependency_management.md, documents/engineering/pure_fp_standards.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Guide for Claude Code development on the current `prodbox` worktree baseline.

## Rewrite Posture

- `DEVELOPMENT_PLAN/README.md` is the authoritative live tracker for target architecture, status,
  blockers, and cleanup ownership.
- The repository is Haskell-only on the supported path. The public CLI, lifecycle runtime, Pulumi
  orchestration, gateway runtime, chart platform, onboarding flow, AWS administration commands,
  and test harness all live under `app/`, `src/Prodbox/`, `test/`, `prodbox.cabal`,
  `cabal.project`, and `Dockerfile`.
- Do not describe removed Python directories or Poetry workflows as the current supported
  architecture.

## Current Worktree Baseline

Prodbox manages a home Kubernetes cluster with a Haskell command surface.

- `app/prodbox/Main.hs` is the executable entrypoint.
- `src/Prodbox/` owns the command parser, runtime modules, infra orchestration, gateway runtime,
  chart platform, AWS administration flows, and test harness.
- `test/` contains the Haskell unit and integration suites.
- `prodbox-config.dhall` is decoded directly into Haskell types; `prodbox-config.json` is not part
  of the supported interface.
- `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, and `pulumi/aws-test/Main.yaml` are the
  supported Pulumi programs.

## Git Workflow Policy

**CRITICAL: Claude Code is NOT authorized to commit or push changes.**

- Never run `git commit`, `git push`, `git add`, or any git command that modifies repository state.
- Leave all changes as uncommitted working directory changes.

## Pure FP Doctrine

> **SSoT**: [Pure FP Standards](documents/engineering/pure_fp_standards.md)

### Purity Boundary

| Code Location | Purity | Allowed |
|---------------|--------|---------|
| DAG builders, renderers, validation helpers | Pure | No I/O |
| Interpreter and command runners | Effectful | Subprocesses, files, network |
| Main command entrypoints | Effectful | Exit orchestration and user-facing rendering |

### Key Rules

1. Keep side effects at command or interpreter boundaries.
2. Prefer explicit ADTs over ad-hoc strings.
3. Use exhaustive pattern matching.
4. Return structured errors for ordinary control flow.
5. Keep configuration decoding and validation explicit.

## Current Worktree CLI Tool

Canonical developer entrypoints:

```bash
cabal build --builddir=.build exe:prodbox
./.build/prodbox --help
./.build/prodbox check-code
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
```

Named infrastructure-backed validation commands such as
`./.build/prodbox test integration aws-iam` and
`./.build/prodbox test integration public-dns`
run real native Haskell validation flows and require the environment named by their prerequisite
contracts.

## Testing Philosophy

> **SSoT**: [Unit Testing Policy](documents/engineering/unit_testing_policy.md)

- Pure code should be testable without mocks.
- Built-frontend CLI and env proof lives in `test/integration/cli/Main.hs` and
  `test/integration/env/Main.hs`.
- Named `prodbox test integration ...` commands execute native validation flows through
  `src/Prodbox/TestValidation.hs`.
- Missing prerequisites must fail fast with actionable errors.

## Documentation

- [Development Plan](./DEVELOPMENT_PLAN/README.md)
- [Engineering Docs Index](./documents/engineering/README.md)
- [CLI Command Surface](./documents/engineering/cli_command_surface.md)
- [Unit Testing Policy](./documents/engineering/unit_testing_policy.md)
