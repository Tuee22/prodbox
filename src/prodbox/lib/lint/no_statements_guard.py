"""Policy guard for statement-heavy control flow in CLI modules."""

from __future__ import annotations

import ast
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root

NO_STATEMENTS_MODE_ENV: str = "PRODBOX_NO_STATEMENTS_MODE"
INFORMATIONAL_MODE: str = "informational"
ENFORCE_MODE: str = "enforce"

_BOUNDARY_ALLOWLIST: frozenset[Path] = frozenset(
    {
        Path("src/prodbox/cli/check_code.py"),
        Path("src/prodbox/cli/command_executor.py"),
        Path("src/prodbox/cli/interpreter.py"),
        Path("src/prodbox/cli/main.py"),
        Path("src/prodbox/cli/test_cmd.py"),
    }
)


@dataclass(frozen=True)
class StatementViolation:
    """A no-statements policy violation."""

    relative_path: Path
    line_number: int
    reason: str


def find_statement_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[StatementViolation, ...]:
    """Find statement-control-flow violations in non-allowlisted CLI files."""
    files = (
        target_files
        if target_files is not None
        else tuple((repo_path / "src" / "prodbox" / "cli").rglob("*.py"))
    )
    violations: list[StatementViolation] = []
    for file_path in sorted(files):
        if not file_path.exists():
            continue
        relative_path = _safe_relative(file_path, repo_path)
        if relative_path in _BOUNDARY_ALLOWLIST:
            continue
        source = file_path.read_text(encoding="utf-8")
        try:
            tree = ast.parse(source, filename=str(file_path))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            violation = _statement_violation(node)
            if violation is None:
                continue
            reason, line_number = violation
            violations.append(
                StatementViolation(
                    relative_path=relative_path,
                    line_number=line_number,
                    reason=reason,
                )
            )
    return tuple(violations)


def _safe_relative(file_path: Path, repo_path: Path) -> Path:
    """Return a stable relative path when possible."""
    try:
        return file_path.relative_to(repo_path)
    except ValueError:
        return file_path


def _statement_violation(node: ast.AST) -> tuple[str, int] | None:
    """Return statement-policy violation tuple for the given AST node."""
    match node:
        case ast.If(lineno=line_number):
            return ("if statement is forbidden; prefer match/case in pure paths", line_number)
        case (
            ast.For(lineno=line_number)
            | ast.AsyncFor(lineno=line_number)
            | ast.While(lineno=line_number)
        ):
            return (
                "loop statement is forbidden; prefer comprehension/reduction patterns",
                line_number,
            )
        case _:
            return None


def _render_violation(violation: StatementViolation) -> str:
    """Render statement-policy violation for stderr."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        "forbidden statement control flow\n"
        f"    reason: {violation.reason}"
    )


def _guard_mode() -> str:
    """Resolve guard execution mode."""
    configured_mode = os.environ.get(NO_STATEMENTS_MODE_ENV, INFORMATIONAL_MODE).strip().lower()
    if configured_mode in (INFORMATIONAL_MODE, ENFORCE_MODE):
        return configured_mode
    return INFORMATIONAL_MODE


def main() -> int:
    """Run no-statements policy guard and return process exit code."""
    root = repo_root()
    mode = _guard_mode()
    violations = find_statement_violations(root)

    if not violations:
        print("no_statements_guard: PASS")
        return 0

    if mode == INFORMATIONAL_MODE:
        print(
            "no_statements_guard: INFO "
            f"({len(violations)} violations, non-blocking in informational mode; "
            f"set {NO_STATEMENTS_MODE_ENV}={ENFORCE_MODE} for blocking details)"
        )
        return 0

    print("no_statements_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
