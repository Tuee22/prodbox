"""Guard enforcing explicit positive timeout wiring for critical CLI runners."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root


@dataclass(frozen=True)
class TimeoutViolation:
    """A timeout policy violation."""

    relative_path: Path
    line_number: int
    reason: str


def find_timeout_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[TimeoutViolation, ...]:
    """Find missing/non-positive RunSubprocess timeout configuration."""
    files = (
        target_files
        if target_files is not None
        else (
            repo_path / "src" / "prodbox" / "cli" / "check_code.py",
            repo_path / "src" / "prodbox" / "cli" / "test_cmd.py",
        )
    )
    violations: list[TimeoutViolation] = []
    for file_path in files:
        if not file_path.exists():
            continue
        source = file_path.read_text(encoding="utf-8")
        try:
            tree = ast.parse(source, filename=str(file_path))
        except SyntaxError:
            continue
        relative_path = file_path.relative_to(repo_path)
        constant_map = _extract_numeric_constants(tree)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            if not _is_run_subprocess_call(node):
                continue
            timeout_keyword = _find_keyword(node, "timeout")
            if timeout_keyword is None:
                violations.append(
                    TimeoutViolation(
                        relative_path=relative_path,
                        line_number=node.lineno,
                        reason="RunSubprocess must define timeout explicitly",
                    )
                )
                continue
            reason = _timeout_reason(timeout_keyword.value, constant_map)
            if reason is not None:
                violations.append(
                    TimeoutViolation(
                        relative_path=relative_path,
                        line_number=node.lineno,
                        reason=reason,
                    )
                )
    return tuple(violations)


def _extract_numeric_constants(tree: ast.Module) -> dict[str, float | None]:
    """Extract module-level constant values (number or None)."""
    constants: dict[str, float | None] = {}
    for node in tree.body:
        match node:
            case ast.Assign(targets=[ast.Name(id=name)], value=ast.Constant(value=value)):
                if isinstance(value, int | float):
                    constants[name] = float(value)
                elif value is None:
                    constants[name] = None
            case ast.AnnAssign(
                target=ast.Name(id=name),
                value=ast.Constant(value=value),
            ):
                if isinstance(value, int | float):
                    constants[name] = float(value)
                elif value is None:
                    constants[name] = None
            case _:
                pass
    return constants


def _is_run_subprocess_call(node: ast.Call) -> bool:
    """Check whether AST call node represents RunSubprocess(...)."""
    match node.func:
        case ast.Name(id="RunSubprocess"):
            return True
        case ast.Attribute(attr="RunSubprocess"):
            return True
        case _:
            return False


def _find_keyword(node: ast.Call, name: str) -> ast.keyword | None:
    """Find named keyword argument on AST call node."""
    for keyword in node.keywords:
        if keyword.arg == name:
            return keyword
    return None


def _timeout_reason(value: ast.expr, constants: dict[str, float | None]) -> str | None:
    """Return violation reason for timeout AST expression, if any."""
    if isinstance(value, ast.Constant):
        if value.value is None:
            return "RunSubprocess timeout cannot be None"
        if isinstance(value.value, int | float) and float(value.value) <= 0:
            return "RunSubprocess timeout must be > 0"
        return None
    if isinstance(value, ast.Name):
        resolved = constants.get(value.id)
        if resolved is None:
            return f"RunSubprocess timeout constant '{value.id}' resolves to None/unknown"
        if resolved <= 0:
            return f"RunSubprocess timeout constant '{value.id}' must be > 0"
        return None
    return "RunSubprocess timeout must be numeric or named numeric constant"


def _render_violation(violation: TimeoutViolation) -> str:
    """Render timeout policy violation for stderr."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        "timeout policy violation\n"
        f"    reason: {violation.reason}"
    )


def main() -> int:
    """Run timeout guard and return process exit code."""
    root = repo_root()
    violations = find_timeout_violations(root)
    if not violations:
        print("timeout_guard: PASS")
        return 0
    print("timeout_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
