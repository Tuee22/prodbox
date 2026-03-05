"""Code quality check command."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_executor import execute_effect
from prodbox.cli.effects import RunSubprocess, Sequence, WriteStdout

CHECK_CODE_TIMEOUT_SECONDS: float = 300.0


@click.command("check-code")
def check_code() -> None:
    """Run policy, lint, format-check, and type checks with fail-fast behavior."""
    sys.exit(_run_check_code())


def _run_check_code() -> int:
    """Build and execute the canonical check-code sequence."""
    effects = Sequence(
        effect_id="check_code_sequence",
        description="Run prodbox code quality checks",
        effects=[
            WriteStdout(
                effect_id="check_code_header",
                description="Check-code header",
                text="Running prodbox check-code (policy guard + ruff + mypy)",
            ),
            RunSubprocess(
                effect_id="check_code_policy_guard",
                description="Enforce no direct mypy policy",
                command=["poetry", "run", "python", "-m", "prodbox.lib.lint.no_direct_mypy_guard"],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
            ),
            RunSubprocess(
                effect_id="check_code_ruff_check",
                description="Lint with ruff",
                command=["poetry", "run", "ruff", "check", "src/", "tests/"],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
            ),
            RunSubprocess(
                effect_id="check_code_ruff_format_check",
                description="Verify formatting with ruff format",
                command=["poetry", "run", "ruff", "format", "--check", "src/", "tests/"],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
            ),
            RunSubprocess(
                effect_id="check_code_mypy",
                description="Type check with mypy",
                command=["poetry", "run", "mypy", "src/"],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
            ),
        ],
    )
    return execute_effect(effects)
