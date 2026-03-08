"""Policy guard preventing type escape hatches in CLI modules."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root


@dataclass(frozen=True)
class TypeEscapeViolation:
    """A type escape hatch policy violation."""

    relative_path: Path
    line_number: int
    reason: str


def find_type_escape_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[TypeEscapeViolation, ...]:
    """Find disallowed Any/cast/type-ignore usage in target files."""
    files = (
        target_files
        if target_files is not None
        else tuple((repo_path / "src" / "prodbox" / "cli").rglob("*.py"))
    )
    violations: list[TypeEscapeViolation] = []
    for file_path in files:
        if not file_path.exists():
            continue
        source = file_path.read_text(encoding="utf-8")
        try:
            tree = ast.parse(source, filename=str(file_path))
        except SyntaxError:
            continue
        relative_path = file_path.relative_to(repo_path)

        for line_number, line_text in enumerate(source.splitlines(), start=1):
            if "# type: ignore" in line_text:
                violations.append(
                    TypeEscapeViolation(
                        relative_path=relative_path,
                        line_number=line_number,
                        reason="`# type: ignore` is forbidden in CLI modules",
                    )
                )

        for node in ast.walk(tree):
            match node:
                case ast.ImportFrom(module="typing", names=names):
                    for alias in names:
                        if alias.name == "Any":
                            violations.append(
                                TypeEscapeViolation(
                                    relative_path=relative_path,
                                    line_number=node.lineno,
                                    reason="typing.Any import is forbidden",
                                )
                            )
                case ast.Name(id="Any"):
                    violations.append(
                        TypeEscapeViolation(
                            relative_path=relative_path,
                            line_number=node.lineno,
                            reason="Any annotation is forbidden",
                        )
                    )
                case ast.Call(func=ast.Name(id="cast")):
                    violations.append(
                        TypeEscapeViolation(
                            relative_path=relative_path,
                            line_number=node.lineno,
                            reason="typing.cast(...) is forbidden",
                        )
                    )
                case _:
                    pass
    return tuple(violations)


def _render_violation(violation: TypeEscapeViolation) -> str:
    """Render type escape policy violation for stderr."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        f"forbidden type escape\n"
        f"    reason: {violation.reason}"
    )


def main() -> int:
    """Run type escape policy guard and return process exit code."""
    root = repo_root()
    violations = find_type_escape_violations(root)
    if not violations:
        print("type_escape_guard: PASS")
        return 0
    print("type_escape_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
