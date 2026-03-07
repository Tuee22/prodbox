"""Policy guard preventing pytest skip/xfail usage in this repository's tests."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root

_TARGET_DIRS: tuple[str, ...] = ("tests",)
_FORBIDDEN_MARKER_DECORATORS: frozenset[str] = frozenset({"skip", "skipif", "xfail"})
_FORBIDDEN_PYTEST_CALLS: frozenset[str] = frozenset({"skip", "xfail"})


@dataclass(frozen=True)
class AliasContext:
    """Import alias context for a Python module."""

    pytest_aliases: frozenset[str]
    mark_aliases: frozenset[str]
    direct_call_aliases: frozenset[str]


@dataclass(frozen=True)
class SkipPolicyViolation:
    """A skip/xfail policy violation found in a Python file."""

    relative_path: Path
    line_number: int
    column: int
    line_text: str
    reason: str


def find_skip_policy_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[SkipPolicyViolation, ...]:
    """Find all forbidden pytest skip/xfail constructs."""
    files_to_scan = target_files if target_files is not None else _python_files_to_scan(repo_path)
    violations: list[SkipPolicyViolation] = []

    for file_path in files_to_scan:
        if not file_path.exists():
            continue

        source = file_path.read_text(encoding="utf-8")
        source_lines = tuple(source.splitlines())
        relative_path = file_path.relative_to(repo_path)

        try:
            tree = ast.parse(source, filename=str(file_path))
        except SyntaxError as error:
            line_number = error.lineno if error.lineno is not None else 1
            column = error.offset if error.offset is not None else 1
            violations.append(
                SkipPolicyViolation(
                    relative_path=relative_path,
                    line_number=line_number,
                    column=column,
                    line_text=_line_at(source_lines, line_number),
                    reason=f"Unable to parse Python file: {error.msg}",
                )
            )
            continue

        aliases = _collect_aliases(tree)
        violations.extend(
            _scan_module_for_violations(
                tree=tree,
                aliases=aliases,
                relative_path=relative_path,
                source_lines=source_lines,
            )
        )

    return tuple(violations)


def _python_files_to_scan(repo_path: Path) -> tuple[Path, ...]:
    """Return sorted Python test files to scan for policy violations."""
    paths: list[Path] = []
    for relative_dir in _TARGET_DIRS:
        directory = repo_path / relative_dir
        if not directory.exists():
            continue
        paths.extend(sorted(directory.rglob("*.py")))
    return tuple(paths)


def _collect_aliases(tree: ast.Module) -> AliasContext:
    """Collect import aliases relevant to pytest skip/xfail detection."""
    pytest_aliases: set[str] = {"pytest"}
    mark_aliases: set[str] = set()
    direct_call_aliases: set[str] = set()

    for statement in tree.body:
        match statement:
            case ast.Import(names=names):
                for alias in names:
                    if alias.name == "pytest":
                        pytest_aliases.add(alias.asname if alias.asname is not None else "pytest")
            case ast.ImportFrom(module="pytest", names=names):
                for alias in names:
                    binding = alias.asname if alias.asname is not None else alias.name
                    if alias.name == "mark":
                        mark_aliases.add(binding)
                    if alias.name in _FORBIDDEN_PYTEST_CALLS:
                        direct_call_aliases.add(binding)
            case _:
                continue

    return AliasContext(
        pytest_aliases=frozenset(pytest_aliases),
        mark_aliases=frozenset(mark_aliases),
        direct_call_aliases=frozenset(direct_call_aliases),
    )


def _scan_module_for_violations(
    *,
    tree: ast.Module,
    aliases: AliasContext,
    relative_path: Path,
    source_lines: tuple[str, ...],
) -> tuple[SkipPolicyViolation, ...]:
    """Scan one module AST for skip/xfail policy violations."""
    violations: list[SkipPolicyViolation] = []

    for node in ast.walk(tree):
        match node:
            case ast.Call():
                reason = _classify_call_violation(node, aliases)
                if reason is not None:
                    violations.append(
                        SkipPolicyViolation(
                            relative_path=relative_path,
                            line_number=node.lineno,
                            column=node.col_offset + 1,
                            line_text=_line_at(source_lines, node.lineno),
                            reason=reason,
                        )
                    )
            case ast.FunctionDef() | ast.AsyncFunctionDef() | ast.ClassDef():
                for decorator in node.decorator_list:
                    reason = _classify_decorator_violation(decorator, aliases)
                    if reason is not None:
                        violations.append(
                            SkipPolicyViolation(
                                relative_path=relative_path,
                                line_number=decorator.lineno,
                                column=decorator.col_offset + 1,
                                line_text=_line_at(source_lines, decorator.lineno),
                                reason=reason,
                            )
                        )
            case _:
                continue

    return tuple(violations)


def _classify_call_violation(call: ast.Call, aliases: AliasContext) -> str | None:
    """Return violation reason for forbidden call, if present."""
    path = _attribute_path(call.func)
    if path is None:
        return None

    if len(path) == 1 and path[0] in aliases.direct_call_aliases:
        return f"Forbidden pytest call alias '{path[0]}(...)'"

    if len(path) >= 2 and path[0] in aliases.pytest_aliases and path[1] in _FORBIDDEN_PYTEST_CALLS:
        return f"Forbidden pytest call '{'.'.join(path)}(...)'"

    return None


def _classify_decorator_violation(decorator: ast.expr, aliases: AliasContext) -> str | None:
    """Return violation reason for forbidden decorator, if present."""
    target = decorator.func if isinstance(decorator, ast.Call) else decorator
    path = _attribute_path(target)
    if path is None:
        return None

    if _is_forbidden_marker_path(path, aliases):
        return f"Forbidden pytest decorator '{'.'.join(path)}'"

    return None


def _is_forbidden_marker_path(path: tuple[str, ...], aliases: AliasContext) -> bool:
    """Check whether attribute path identifies a forbidden pytest marker."""
    if len(path) == 3 and path[0] in aliases.pytest_aliases and path[1] == "mark":
        return path[2] in _FORBIDDEN_MARKER_DECORATORS

    if len(path) == 2 and path[0] in aliases.mark_aliases:
        return path[1] in _FORBIDDEN_MARKER_DECORATORS

    return False


def _attribute_path(expr: ast.expr) -> tuple[str, ...] | None:
    """Extract dotted attribute path from an expression."""
    match expr:
        case ast.Name(id=name):
            return (name,)
        case ast.Attribute(value=value, attr=attr):
            prefix = _attribute_path(value)
            if prefix is None:
                return None
            return (*prefix, attr)
        case _:
            return None


def _line_at(lines: tuple[str, ...], line_number: int) -> str:
    """Return source line text for a 1-based line number."""
    if 1 <= line_number <= len(lines):
        return lines[line_number - 1].strip()
    return ""


def _render_violation(violation: SkipPolicyViolation) -> str:
    """Render one policy violation for terminal output."""
    return (
        f"{violation.relative_path}:{violation.line_number}:{violation.column}: "
        f"{violation.reason}\n"
        f"    {violation.line_text}"
    )


def main() -> int:
    """Run skip/xfail policy guard and return exit code."""
    repo_path = repo_root()
    violations = find_skip_policy_violations(repo_path)
    match len(violations):
        case 0:
            print("no_test_skip_guard: PASS")
            return 0
        case _:
            print("no_test_skip_guard: FAIL", file=sys.stderr)
            print(
                "Skip/xfail usage is forbidden. Enforce prerequisites before tests run.",
                file=sys.stderr,
            )
            for violation in violations:
                print(_render_violation(violation), file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
