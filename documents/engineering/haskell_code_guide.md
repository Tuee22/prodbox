# Haskell Code Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](../../README.md), [../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md), [README.md](./README.md), [code_quality.md](./code_quality.md), [dependency_management.md](./dependency_management.md), [pure_fp_standards.md](./pure_fp_standards.md)

> **Purpose**: Define the repository's Haskell coding standards, the hard mechanical gates that
> enforce them, and the review guidance that remains human-judged.

## 1. Scope

This guide applies to the supported Haskell worktree:

- `app/`
- `src/Prodbox/`
- `test/`
- `prodbox.cabal`
- `cabal.project`
- repository-owned Dockerfiles under `docker/` where the Haskell build gate is invoked

This document complements, rather than replaces:

- [Code Quality Doctrine](./code_quality.md) for the public `prodbox check-code` contract
- [Pure FP Standards](./pure_fp_standards.md) for purity, ADT, and effect-boundary doctrine
- [Dependency Management](./dependency_management.md) for host-tool and package ownership

## 2. Standards Model

This repository uses two kinds of Haskell standards.

### 2.1 Hard Gates

Hard gates are enforced mechanically. A change that fails one of these gates is incomplete.

Current hard gates:

- repository-owned workflow and hook policy scan through `prodbox check-code`
- Fourmolu formatting through the checked-in [`fourmolu.toml`](../../fourmolu.toml)
- HLint through the checked-in [`/.hlint.yaml`](../../.hlint.yaml)
- warning-clean Haskell compilation through
  `cabal build --builddir=.build all --ghc-options=-Werror`
- operator-binary sync to `./.build/prodbox` after a successful quality gate

### 2.2 Review Guidance

Review guidance is still part of the coding standard, but it is not mechanically proven by the
formatter or compiler switch.

Current review guidance includes:

- prefer explicit ADTs and pattern matches over stringly control flow
- keep side effects at CLI, interpreter, or subprocess boundaries
- isolate pure helpers around parsing, rendering, and planning logic
- keep modules cohesive around one owned runtime or domain surface
- add brief comments only when control flow is genuinely non-obvious

The build must not pretend to enforce guidance that it cannot actually prove.

## 3. Repository-Owned Inputs

The current repository-owned Haskell style and lint inputs are:

- [`fourmolu.toml`](../../fourmolu.toml) for formatting
- [`.hlint.yaml`](../../.hlint.yaml) for lint policy
- [`.editorconfig`](../../.editorconfig) for editor ergonomics only

Important distinction:

- `fourmolu.toml` is a hard-gate input
- `.hlint.yaml` is a hard-gate input
- `.editorconfig` is not a build-acceptance input

## 4. Canonical Commands

The authoritative mechanical Haskell quality gate is:

```bash
./.build/prodbox check-code
```

`src/Prodbox/CheckCode.hs` owns that command. The supported gate currently requires:

1. repository-owned workflow and hook policy scan
2. `fourmolu --mode check app src test`
3. `hlint app src test --hint=.hlint.yaml`
4. `cabal build --builddir=.build all --ghc-options=-Werror`
5. sync of the built operator binary to `./.build/prodbox`

The broader validation surfaces remain separate:

```bash
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
./.build/prodbox test all
```

Those suites validate runtime behavior and owned proof flows. They do not replace `check-code` as
the canonical formatter/linter/warning-clean gate.

## 5. Tooling Policy

The repository uses local CLI entrypoints only. CI workflows, `.github/` automation, and git hooks
are not part of the supported development model, and `prodbox check-code` fails on repo-owned
workflow or hook surfaces that would violate that policy.

See [Code Quality Doctrine](./code_quality.md#2a-development-tooling-policy) for the public policy
statement.

## Cross-References

- [Code Quality Doctrine](./code_quality.md)
- [Pure FP Standards](./pure_fp_standards.md)
- [Dependency Management](./dependency_management.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
