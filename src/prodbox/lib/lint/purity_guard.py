"""Guard enforcing interpreter-bound impurity and pure DAG builder boundaries."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root

_INTERPRETER_CALL_ALLOWLIST: frozenset[Path] = frozenset(
    {
        Path("src/prodbox/cli/command_executor.py"),
        Path("src/prodbox/cli/interpreter.py"),
    }
)

_PURE_MODULES: tuple[Path, ...] = (
    Path("src/prodbox/cli/dag_builders.py"),
    Path("src/prodbox/cli/effect_dag.py"),
    Path("src/prodbox/cli/command_adt.py"),
)

_BANNED_PURE_CALLS: frozenset[str] = frozenset(
    {
        "_run_subprocess",
        "create_subprocess_exec",
        "popen",
        "run_command",
        "run_shell",
        "print",
        "open",
    }
)


@dataclass(frozen=True)
class PurityViolation:
    """A purity policy violation."""

    relative_path: Path
    line_number: int
    reason: str


def find_purity_violations(repo_path: Path) -> tuple[PurityViolation, ...]:
    """Find purity violations across interpreter boundary and pure modules."""
    violations: list[PurityViolation] = []
    violations.extend(_find_interpreter_boundary_violations(repo_path))
    violations.extend(_find_pure_module_call_violations(repo_path))
    return tuple(violations)


def _find_interpreter_boundary_violations(repo_path: Path) -> list[PurityViolation]:
    violations: list[PurityViolation] = []
    for file_path in (repo_path / "src" / "prodbox").rglob("*.py"):
        rel = file_path.relative_to(repo_path)
        if rel in _INTERPRETER_CALL_ALLOWLIST:
            continue
        source = file_path.read_text(encoding="utf-8")
        try:
            tree = ast.parse(source, filename=str(file_path))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            match node.func:
                case ast.Name(id="create_interpreter") | ast.Name(id="EffectInterpreter"):
                    violations.append(
                        PurityViolation(
                            relative_path=rel,
                            line_number=node.lineno,
                            reason="interpreter construction/use outside command_executor/interpreter",
                        )
                    )
                case _:
                    pass
    return violations


def _find_pure_module_call_violations(repo_path: Path) -> list[PurityViolation]:
    violations: list[PurityViolation] = []
    for rel in _PURE_MODULES:
        file_path = repo_path / rel
        if not file_path.exists():
            continue
        source = file_path.read_text(encoding="utf-8")
        try:
            tree = ast.parse(source, filename=str(file_path))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            target = _call_target_name(node.func)
            if target is None or target not in _BANNED_PURE_CALLS:
                continue
            violations.append(
                PurityViolation(
                    relative_path=rel,
                    line_number=node.lineno,
                    reason=f"banned side-effect call '{target}' in pure module",
                )
            )
    return violations


def _call_target_name(node: ast.expr) -> str | None:
    """Extract simple call target name from AST call target."""
    match node:
        case ast.Name(id=name):
            return name
        case ast.Attribute(attr=attr):
            return attr
        case _:
            return None


def _render_violation(violation: PurityViolation) -> str:
    """Render purity violation for stderr."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        "purity violation\n"
        f"    reason: {violation.reason}"
    )


def main() -> int:
    """Run purity guard and return process exit code."""
    root = repo_root()
    violations = find_purity_violations(root)
    if not violations:
        print("purity_guard: PASS")
        return 0
    print("purity_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
