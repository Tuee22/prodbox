"""Policy guard preventing non-entrypoint `poetry run` usage in docs/automation."""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import (
    load_entrypoint_policy,
    parse_poetry_run_command,
    repo_root,
)

_TARGET_FILES: tuple[str, ...] = (
    "AGENTS.md",
    "CLAUDE.md",
    "README.md",
    "PRODBOX_PLAN.md",
    ".github/workflows/ci.yml",
    "Containerfile.gateway",
    "documents/engineering/dependency_management.md",
    "documents/engineering/distributed_gateway_architecture.md",
    "documents/engineering/tla/README.md",
    "documents/engineering/tla_modelling_assumptions.md",
    "documents/engineering/unit_testing_policy.md",
)


@dataclass(frozen=True)
class PolicyViolation:
    """A policy violation for non-entrypoint Poetry usage."""

    relative_path: Path
    line_number: int
    line_text: str
    command: str


def find_policy_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
) -> tuple[PolicyViolation, ...]:
    """Find `poetry run` commands that are not entrypoints."""
    pyproject_path = repo_path / "pyproject.toml"
    policy = load_entrypoint_policy(pyproject_path)
    allowed = policy.allowed_entrypoints
    files_to_scan = (
        target_files
        if target_files is not None
        else tuple(repo_path / relative_path for relative_path in _TARGET_FILES)
    )
    violations: list[PolicyViolation] = []

    for file_path in files_to_scan:
        if not file_path.exists():
            continue
        relative_path = file_path.relative_to(repo_path)
        for line_number, line_text in enumerate(
            file_path.read_text(encoding="utf-8").splitlines(), 1
        ):
            command = parse_poetry_run_command(line_text)
            match command:
                case None:
                    continue
                case value if value in allowed:
                    continue
                case value:
                    violations.append(
                        PolicyViolation(
                            relative_path=relative_path,
                            line_number=line_number,
                            line_text=line_text.strip(),
                            command=value,
                        )
                    )

    return tuple(violations)


def _render_violation(violation: PolicyViolation) -> str:
    """Render a policy violation for console output."""
    return (
        f"{violation.relative_path}:{violation.line_number}: "
        "non-entrypoint poetry run command is forbidden\n"
        f"    {violation.line_text}"
    )


def main() -> int:
    """Run no-direct-poetry-run policy guard and return exit code."""
    repo_path = repo_root()
    violations = find_policy_violations(repo_path)
    match len(violations):
        case 0:
            print("no_direct_poetry_run_guard: PASS")
            return 0
        case _:
            print("no_direct_poetry_run_guard: FAIL", file=sys.stderr)
            print(
                "Use `poetry run prodbox <command>` entrypoints for all tooling.",
                file=sys.stderr,
            )
            for violation in violations:
                print(_render_violation(violation), file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
