"""Policy guard preventing threading/multiprocessing in CLI architecture."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root


@dataclass(frozen=True)
class ThreadingViolation:
    """A threading policy violation."""

    relative_path: Path
    line_number: int
    reason: str


def find_threading_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[ThreadingViolation, ...]:
    """Find disallowed threading/multiprocessing usage in target files."""
    files = (
        target_files
        if target_files is not None
        else tuple((repo_path / "src" / "prodbox" / "cli").rglob("*.py"))
    )
    violations: list[ThreadingViolation] = []
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
            match node:
                case ast.Import(names=names):
                    for alias in names:
                        if alias.name in {"threading", "multiprocessing"}:
                            violations.append(
                                ThreadingViolation(
                                    relative_path=relative_path,
                                    line_number=node.lineno,
                                    reason=f"import of '{alias.name}' is forbidden",
                                )
                            )
                case ast.ImportFrom(module=module) if module in {"threading", "multiprocessing"}:
                    violations.append(
                        ThreadingViolation(
                            relative_path=relative_path,
                            line_number=node.lineno,
                            reason=f"from {module} import ... is forbidden",
                        )
                    )
                case ast.Attribute(value=ast.Name(id=owner), attr=attr):
                    if owner in {"threading", "multiprocessing"}:
                        violations.append(
                            ThreadingViolation(
                                relative_path=relative_path,
                                line_number=node.lineno,
                                reason=f"{owner}.{attr} usage is forbidden",
                            )
                        )
                case _:
                    pass
    return tuple(violations)


def _render_violation(violation: ThreadingViolation) -> str:
    """Render threading policy violation for stderr."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        f"forbidden threading usage\n"
        f"    reason: {violation.reason}"
    )


def main() -> int:
    """Run threading policy guard and return process exit code."""
    root = repo_root()
    violations = find_threading_violations(root)
    if not violations:
        print("no_threading_guard: PASS")
        return 0
    print("no_threading_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
