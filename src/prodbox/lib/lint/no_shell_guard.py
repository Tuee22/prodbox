"""Policy guard preventing shell-mode subprocess execution in CLI modules."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root


@dataclass(frozen=True)
class ShellViolation:
    """A shell invocation policy violation."""

    relative_path: Path
    line_number: int
    reason: str


def find_shell_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[ShellViolation, ...]:
    """Find shell-mode subprocess invocations in target files."""
    files = (
        target_files
        if target_files is not None
        else tuple((repo_path / "src" / "prodbox" / "cli").rglob("*.py"))
    )
    violations: list[ShellViolation] = []
    for file_path in files:
        if not file_path.exists():
            continue
        source = file_path.read_text(encoding="utf-8")
        try:
            tree = ast.parse(source, filename=str(file_path))
        except SyntaxError:
            continue
        relative_path = file_path.relative_to(repo_path)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            reason = _call_violation_reason(node)
            if reason is None:
                continue
            violations.append(
                ShellViolation(
                    relative_path=relative_path,
                    line_number=node.lineno,
                    reason=reason,
                )
            )
    return tuple(violations)


def _call_violation_reason(node: ast.Call) -> str | None:
    """Return policy reason if call contains a shell invocation pattern."""
    for keyword in node.keywords:
        if keyword.arg != "shell":
            continue
        if isinstance(keyword.value, ast.Constant) and keyword.value.value is True:
            return "shell=True is forbidden; use exec-mode command lists"

    if not node.args:
        return None
    first_arg = node.args[0]
    if (
        isinstance(first_arg, ast.List)
        and len(first_arg.elts) >= 2
        and _is_shell_dash_c(first_arg.elts[0], first_arg.elts[1])
    ):
        return "['sh', '-c', ...] style shell invocation is forbidden"
    if (
        isinstance(first_arg, ast.Tuple)
        and len(first_arg.elts) >= 2
        and _is_shell_dash_c(first_arg.elts[0], first_arg.elts[1])
    ):
        return "('sh', '-c', ...) style shell invocation is forbidden"
    return None


def _is_shell_dash_c(first: ast.expr, second: ast.expr) -> bool:
    """Check literal two-token shell launcher pattern."""
    if not (
        isinstance(first, ast.Constant)
        and isinstance(first.value, str)
        and isinstance(second, ast.Constant)
        and second.value == "-c"
    ):
        return False
    return first.value in {"sh", "/bin/sh"}


def _render_violation(violation: ShellViolation) -> str:
    """Render shell policy violation for stderr."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        f"forbidden shell invocation\n"
        f"    reason: {violation.reason}"
    )


def main() -> int:
    """Run shell policy guard and return process exit code."""
    root = repo_root()
    violations = find_shell_violations(root)
    if not violations:
        print("no_shell_guard: PASS")
        return 0
    print("no_shell_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
