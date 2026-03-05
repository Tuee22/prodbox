"""Policy guard preventing direct mypy command usage in docs and automation."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

_DIRECT_MYPY_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\bpoetry\s+run\s+mypy\b"),
    re.compile(r"^\s*mypy(?:\s+[-\w./]+)+\s*$"),
)

_TARGET_FILES: tuple[str, ...] = (
    "AGENTS.md",
    "CLAUDE.md",
    "README.md",
    "PRODBOX_PLAN.md",
    ".pre-commit-config.yaml",
    ".github/workflows/ci.yml",
    "documents/engineering/dependency_management.md",
)


@dataclass(frozen=True)
class PolicyViolation:
    """A direct-mypy policy violation in a tracked file."""

    relative_path: Path
    line_number: int
    line_text: str


def _repo_root() -> Path:
    """Return repository root from this module path."""
    return Path(__file__).resolve().parents[4]


def _line_has_direct_mypy(line: str) -> bool:
    """Check whether a line contains a direct mypy command invocation."""
    return any(pattern.search(line) for pattern in _DIRECT_MYPY_PATTERNS)


def find_policy_violations(
    repo_root: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[PolicyViolation, ...]:
    """Find direct-mypy command violations in configured files."""
    files_to_scan = (
        target_files
        if target_files is not None
        else tuple(repo_root / relative_path for relative_path in _TARGET_FILES)
    )
    violations: list[PolicyViolation] = []

    for file_path in files_to_scan:
        if not file_path.exists():
            continue
        relative_path = file_path.relative_to(repo_root)
        for line_number, line_text in enumerate(
            file_path.read_text(encoding="utf-8").splitlines(), 1
        ):
            if _line_has_direct_mypy(line_text):
                violations.append(
                    PolicyViolation(
                        relative_path=relative_path,
                        line_number=line_number,
                        line_text=line_text.strip(),
                    )
                )

    return tuple(violations)


def _render_violation(violation: PolicyViolation) -> str:
    """Render a policy violation for console output."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        "direct mypy invocation is forbidden\n"
        f"    {violation.line_text}"
    )


def main() -> int:
    """Run no-direct-mypy policy guard and return process exit code."""
    repo_root = _repo_root()
    violations = find_policy_violations(repo_root)
    match len(violations):
        case 0:
            print("no_direct_mypy_guard: PASS")
            return 0
        case _:
            print("no_direct_mypy_guard: FAIL", file=sys.stderr)
            print(
                "Use `poetry run prodbox check-code` as the canonical type-check entrypoint.",
                file=sys.stderr,
            )
            for violation in violations:
                print(_render_violation(violation), file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
