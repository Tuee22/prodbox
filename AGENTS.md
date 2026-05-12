# Repository Guidelines for Agents

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md, HASKELL_CLI_TOOL.md, documents/documentation_standards.md, documents/engineering/README.md, documents/engineering/pure_fp_standards.md
**Generated sections**: none

> **Purpose**: Agent-facing repository rules for structure, tooling, and coding standards.

`DEVELOPMENT_PLAN/README.md` is the authoritative source for target architecture, sprint status,
and cleanup ownership. [HASKELL_CLI_TOOL.md](HASKELL_CLI_TOOL.md) is the authoritative source
for the CLI doctrine — command topology, generated artifacts, daemon lifecycle, lint
discipline, and the testing stack. The repository is Haskell-only on the supported path.

## Current Worktree Structure

```text
prodbox/
├── app/prodbox/Main.hs   # Haskell executable entrypoint
├── src/Prodbox/          # Haskell runtime, CLI, infra, and library modules
├── test/                 # Haskell unit and integration test suites
├── documents/            # Engineering documentation
├── DEVELOPMENT_PLAN/     # Plan, phase status, and cleanup ownership
├── docker/               # Canonical container builds under /opt/build
├── prodbox.cabal         # Cabal package definition
├── cabal.project         # Cabal project config
```

Do not describe removed Python directories as the current or target architecture.

## Current Worktree Commands

```bash
# Build the operator binary
cabal build --builddir=.build exe:prodbox
mkdir -p .build
cp "$(cabal list-bin --builddir=.build exe:prodbox)" .build/prodbox
chmod +x .build/prodbox

# Run the canonical quality gate
./.build/prodbox check-code

# Run tests
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
./.build/prodbox test all
```

`prodbox check-code` is the required single entrypoint for doctrine enforcement in local
development.

## Coding Style

### Haskell Baseline

- Use explicit data types and pattern matches.
- Keep side effects at command or interpreter boundaries.
- Prefer small pure helpers around subprocess or rendering logic.
- Add brief comments only when the control flow is non-obvious.

### Data And Control-Flow Doctrine

> **SSoT**: [Pure FP Standards](documents/engineering/pure_fp_standards.md)

- Favor explicit ADTs over stringly-typed control flow.
- Handle all known cases explicitly in pattern matches.
- Return structured errors instead of relying on exceptions for ordinary control flow.
- Keep configuration decoding and validation separate from command execution.

## Testing Guidelines

### Unit Tests

- Test pure helpers in isolation.
- Keep mocks at the subprocess or interpreter boundary.
- Prefer table-shaped assertions over incidental output snapshots.

### Integration Tests

- `test/integration/cli/Main.hs` and `test/integration/env/Main.hs` are built-frontend Haskell
  suites.
- Named `prodbox test integration ...` commands run real native Haskell validation flows through
  `src/Prodbox/TestValidation.hs`.
- Missing prerequisites must fail fast with actionable errors.
- Use `./.build/prodbox test unit` when integration prerequisites are unavailable.

### Development Tooling Policy

- Do not use `.github/` workflows or CI automation for this repository during active development.
- Do not use git hooks (including pre-commit); run CLI entrypoints directly.
- See [Code Quality Doctrine](documents/engineering/code_quality.md#2a-development-tooling-policy).

## Commit Guidelines

**CRITICAL: Agents NEVER commit or push.**

- Leave all changes as uncommitted working directory changes.
- Do not run `git commit`, `git push`, or `git add`.
- Do not run git commands that modify repository state.

## Security

- Store AWS auth only in the repository Dhall config (`prodbox-config.dhall`).
- AWS auth must come only from Dhall config; ambient AWS auth env vars, shared-profile discovery,
  and system `aws` CLI host auth state are not valid auth sources for supported `prodbox` flows.
- Validate all external input, especially FQDN and IP address values.
- Keep IAM scopes least-privilege.

## Cross-References

- **CLAUDE.md**: Detailed AI assistant guidelines
- **[HASKELL_CLI_TOOL.md](HASKELL_CLI_TOOL.md)**: Canonical Haskell CLI doctrine
- **documents/documentation_standards.md**: Documentation rules
- **documents/engineering/**: Architecture and doctrine documentation
- **[DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md)**: Development plan, sprint status, and cleanup ownership
