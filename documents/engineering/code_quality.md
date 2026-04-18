# Code Quality Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, documents/engineering/README.md, documents/engineering/cli_command_surface.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/pure_fp_standards.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Define policy guardrails and enforcement flow for `prodbox check-code`.

## 1. Guardrail Statement

Side effects are interpreter-boundary only; policy guards in `check-code` are mandatory and
blocking.

## 2. Canonical Enforcement Entry Point

All policy, formatting, build, and host-side executable-proof closure flow through the canonical
operator entrypoint:

```bash
./.build/prodbox check-code
```

`src/Prodbox/CheckCode.hs` owns that command. The current Haskell implementation runs a fail-fast
sequence:

1. `cabal build --builddir=.build all`
2. Sync the built operator binary to `.build/prodbox`

Local closure on the April 18, 2026 worktree also includes:

```bash
cabal build --builddir=.build exe:prodbox
cabal test --builddir=.build test:prodbox-unit test:prodbox-integration-cli test:prodbox-integration-env
```

## 2A. Development Tooling Policy

Project is in active development; CI pipelines, `.github` workflows, and git hooks (including
pre-commit) are not part of the supported workflow.

Do not add or rely on:

1. `.github/` workflow automation
2. Git hook scripts (`.git/hooks`, pre-commit, or similar)

Use local CLI entrypoints only:

```bash
./.build/prodbox check-code
./.build/prodbox test all
```

## 3. Guard Coverage

Current enforced quality surfaces:

- Haskell buildability through `cabal build --builddir=.build all`
- Operator-binary sync to `./.build/prodbox`
- Test-suite compilation through the Cabal build
- Doctrine alignment described by the governed docs in this directory

Doctrine violations must fail with a non-zero exit code.

## 4. Testing Policy Link

Skip/xfail enforcement, phase-banner doctrine, prerequisite gates, and named validation-harness
behavior are defined in [Unit Testing Policy](./unit_testing_policy.md).

## 5. Intent Ownership

This SSoT co-owns purity and guardrail doctrine intention.

- Owned statement: Side effects are interpreter-boundary only; policy guards in `check-code` are
  mandatory and blocking.
- Linked dependents: `src/Prodbox/CheckCode.hs`, `prodbox.cabal`, `test/unit/Main.hs`.

## Cross-References

- [Pure FP Standards](./pure_fp_standards.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
