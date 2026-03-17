# Code Quality Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, CLAUDE.md, AGENTS.md, documents/engineering/cli_command_surface.md

> **Purpose**: Define policy guardrails and enforcement flow for `prodbox check-code`.

---

## 1. Guardrail Statement

Side effects are interpreter-boundary only; policy guards in check-code are mandatory and blocking.

---

## 2. Canonical Enforcement Entry Point

All policy, lint, formatting, and type checks run through:

```bash
poetry run prodbox check-code
```

The command runs a fail-fast sequence:

1. Policy guards (`no_direct_poetry_run_guard`, `no_test_skip_guard`, purity/no-statements/shell/threading/type/collision/click-passthrough/timeout, docs lint)
2. `ruff check`
3. `ruff format --check`
4. `mypy`

---

## 2A. Development Tooling Policy

Project is in active development; CI pipelines, `.github` workflows, and git hooks (including pre-commit) are not part of the supported workflow.

Do not add or rely on:

1. `.github/` workflow automation
2. Git hook scripts (`.git/hooks`, pre-commit, or similar)

Use local CLI entrypoints only:

```bash
poetry run prodbox check-code
poetry run prodbox test all
```

---

## 3. Guard Coverage

Current guard set:

- `purity_guard`
- `no_statements_guard` (default `enforce` mode; set `PRODBOX_NO_STATEMENTS_MODE=informational` for non-blocking migration diagnostics)
- `no_shell_guard`
- `no_threading_guard`
- `type_escape_guard`
- `command_name_collision_guard`
- `click_passthrough_guard`
- `timeout_guard`
- `no_test_skip_guard`
- `doc_lint_guard`

Doctrine violations must fail with non-zero exit unless an individual guard is explicitly configured for informational output.

---

## 4. Testing Policy Link

Skip/xfail enforcement and timeout doctrine for test execution are part of quality enforcement and are validated in `check-code`.

---

## 5. Intent Ownership

This SSoT co-owns purity and guardrail doctrine intention.

- Owned statement: Side effects are interpreter-boundary only; policy guards in check-code are mandatory and blocking.
- Linked dependents: `src/prodbox/cli/check_code.py`, `src/prodbox/lib/lint/*.py`, `tests/unit/test_check_code_command.py`.

---

## Cross-References

- [Pure FP Standards](./pure_fp_standards.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
