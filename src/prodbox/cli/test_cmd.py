"""Test command for running pytest through the prodbox CLI."""

from __future__ import annotations

import os
import sys

import click

from prodbox.cli.command_executor import execute_effect
from prodbox.cli.effects import RunSubprocess, Sequence, WriteStdout
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV

TEST_TIMEOUT_SECONDS: float | None = None


@click.command(
    "test",
    context_settings={"ignore_unknown_options": True, "allow_extra_args": True},
)
@click.pass_context
def test_cmd(ctx: click.Context) -> None:
    """Run pytest through the prodbox CLI."""
    sys.exit(_run_tests(tuple(ctx.args)))


def _run_tests(args: tuple[str, ...]) -> int:
    """Build and execute a pytest run."""
    env = dict(os.environ)
    env[ALLOW_NON_ENTRYPOINT_ENV] = "1"
    command = [sys.executable, "-m", "pytest", *args]
    effects = Sequence(
        effect_id="pytest_sequence",
        description="Run pytest",
        effects=[
            WriteStdout(
                effect_id="pytest_header",
                description="pytest header",
                text="Running pytest via prodbox CLI",
            ),
            RunSubprocess(
                effect_id="pytest_run",
                description="Execute pytest",
                command=command,
                stream_stdout=True,
                timeout=TEST_TIMEOUT_SECONDS,
                env=env,
            ),
        ],
    )
    return execute_effect(effects)
