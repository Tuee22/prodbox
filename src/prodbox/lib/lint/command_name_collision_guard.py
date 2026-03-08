"""Guard against Click command names that collide with pytest test_* discovery."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root


@dataclass(frozen=True)
class CommandNameCollisionViolation:
    """A Click command naming policy violation."""

    relative_path: Path
    line_number: int
    function_name: str


def find_command_name_collisions(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[CommandNameCollisionViolation, ...]:
    """Find Click command functions using forbidden test_* prefix."""
    files = (
        target_files
        if target_files is not None
        else tuple((repo_path / "src" / "prodbox" / "cli").rglob("*.py"))
    )
    violations: list[CommandNameCollisionViolation] = []
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
            if not isinstance(node, ast.FunctionDef):
                continue
            if not node.name.startswith("test_"):
                continue
            if not _has_click_command_like_decorator(node.decorator_list):
                continue
            violations.append(
                CommandNameCollisionViolation(
                    relative_path=relative_path,
                    line_number=node.lineno,
                    function_name=node.name,
                )
            )
    return tuple(violations)


def _has_click_command_like_decorator(decorators: list[ast.expr]) -> bool:
    """Return True when function decorators define a Click command/group."""
    for decorator in decorators:
        match decorator:
            case ast.Call(func=ast.Attribute(attr=attr)) if attr in {"command", "group"}:
                return True
            case ast.Attribute(attr=attr) if attr in {"command", "group"}:
                return True
            case _:
                pass
    return False


def _render_violation(violation: CommandNameCollisionViolation) -> str:
    """Render command-name collision violation for stderr."""
    suggestion = violation.function_name.removeprefix("test_")
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        "forbidden click command name prefix\n"
        f"    function: {violation.function_name}\n"
        f"    suggestion: {suggestion}"
    )


def main() -> int:
    """Run command-name collision guard and return process exit code."""
    root = repo_root()
    violations = find_command_name_collisions(root)
    if not violations:
        print("command_name_collision_guard: PASS")
        return 0
    print("command_name_collision_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
