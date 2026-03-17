"""Guard against Click passthrough patterns in the prodbox CLI."""

from __future__ import annotations

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root


@dataclass(frozen=True)
class ClickPassthroughViolation:
    """A Click passthrough policy violation."""

    relative_path: Path
    line_number: int
    reason: str


def find_click_passthrough_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[ClickPassthroughViolation, ...]:
    """Find Click decorators that permit undeclared passthrough arguments."""
    files = (
        target_files
        if target_files is not None
        else tuple((repo_path / "src" / "prodbox" / "cli").rglob("*.py"))
    )
    violations: list[ClickPassthroughViolation] = []
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
            passthrough_reason = _passthrough_reason(node)
            if passthrough_reason is None:
                continue
            violations.append(
                ClickPassthroughViolation(
                    relative_path=relative_path,
                    line_number=node.lineno,
                    reason=passthrough_reason,
                )
            )
    return tuple(violations)


def _passthrough_reason(node: ast.Call) -> str | None:
    """Return a violation reason when an AST call enables passthrough."""
    if _is_click_command_like_call(node):
        context_settings_keyword = _find_keyword(node, "context_settings")
        if context_settings_keyword is not None:
            return _context_settings_passthrough_reason(context_settings_keyword.value)
        return None
    if _is_click_argument_call(node):
        nargs_reason = _nargs_passthrough_reason(node)
        if nargs_reason is not None:
            return nargs_reason
        return _unprocessed_passthrough_reason(node)
    return None


def _is_click_command_like_call(node: ast.Call) -> bool:
    """Return True when node is a Click command/group decorator call."""
    match node.func:
        case ast.Attribute(attr=attr) if attr in {"command", "group"}:
            return True
        case _:
            return False


def _is_click_argument_call(node: ast.Call) -> bool:
    """Return True when node is a Click argument declaration."""
    match node.func:
        case ast.Attribute(attr="argument"):
            return True
        case _:
            return False


def _find_keyword(node: ast.Call, name: str) -> ast.keyword | None:
    """Return keyword argument with the given name, if present."""
    for keyword in node.keywords:
        if keyword.arg == name:
            return keyword
    return None


def _context_settings_passthrough_reason(value: ast.expr) -> str | None:
    """Return violation reason for context_settings passthrough flags."""
    if not isinstance(value, ast.Dict):
        return "Click context_settings must not hide passthrough flags"
    for key_node, value_node in zip(value.keys, value.values, strict=True):
        if not isinstance(key_node, ast.Constant) or not isinstance(key_node.value, str):
            continue
        if key_node.value not in {"allow_extra_args", "ignore_unknown_options"}:
            continue
        if _is_true_constant(value_node):
            return f"Click context_settings enables forbidden passthrough flag '{key_node.value}'"
    return None


def _nargs_passthrough_reason(node: ast.Call) -> str | None:
    """Return violation reason for variadic Click arguments."""
    nargs_keyword = _find_keyword(node, "nargs")
    if nargs_keyword is None:
        return None
    if isinstance(nargs_keyword.value, ast.UnaryOp) and isinstance(
        nargs_keyword.value.op, ast.USub
    ):
        operand = nargs_keyword.value.operand
        if isinstance(operand, ast.Constant) and operand.value == 1:
            return "Click argument uses variadic nargs=-1 passthrough"
    return None


def _unprocessed_passthrough_reason(node: ast.Call) -> str | None:
    """Return violation reason for UNPROCESSED Click arguments."""
    type_keyword = _find_keyword(node, "type")
    if type_keyword is None:
        return None
    match type_keyword.value:
        case ast.Attribute(attr="UNPROCESSED"):
            return "Click argument uses click.UNPROCESSED passthrough"
        case ast.Name(id="UNPROCESSED"):
            return "Click argument uses UNPROCESSED passthrough"
        case _:
            return None


def _is_true_constant(value: ast.expr) -> bool:
    """Return True when AST expression is the literal True."""
    return isinstance(value, ast.Constant) and value.value is True


def _render_violation(violation: ClickPassthroughViolation) -> str:
    """Render a Click passthrough violation."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        "click passthrough policy violation\n"
        f"    reason: {violation.reason}"
    )


def main() -> int:
    """Run Click passthrough guard and return process exit code."""
    root = repo_root()
    violations = find_click_passthrough_violations(root)
    if not violations:
        print("click_passthrough_guard: PASS")
        return 0
    print("click_passthrough_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
