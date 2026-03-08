"""Code quality check command."""

from __future__ import annotations

import os
import sys

import click

from prodbox.cli.command_executor import execute_effect
from prodbox.cli.effects import RunSubprocess, Sequence, WriteFile, WriteStdout
from prodbox.lib.lint.entrypoint_guard_installer import (
    guard_install_path,
    guard_script_content,
)
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV
from prodbox.lib.venv_utils import build_tool_command

CHECK_CODE_TIMEOUT_SECONDS: float = 300.0


@click.command("check-code")
def check_code() -> None:
    """Run policy, lint, format-check, and type checks with fail-fast behavior."""
    sys.exit(_run_check_code())


def _run_check_code() -> int:
    """Build and execute the canonical check-code sequence."""
    allow_env = dict(os.environ)
    allow_env[ALLOW_NON_ENTRYPOINT_ENV] = "1"
    ruff_check_command = build_tool_command("ruff", ("check", "src/", "tests/"))
    ruff_format_command = build_tool_command("ruff", ("format", "--check", "src/", "tests/"))
    mypy_command = build_tool_command("mypy", ("src/",))
    guard_path = guard_install_path()
    guard_content = guard_script_content()
    effects = Sequence(
        effect_id="check_code_sequence",
        description="Run prodbox code quality checks",
        effects=[
            WriteStdout(
                effect_id="check_code_header",
                description="Check-code header",
                text="Running prodbox check-code (policy guards + doc lint + ruff + mypy)",
            ),
            WriteFile(
                effect_id="check_code_guard_install",
                description="Install entrypoint guard shim",
                file_path=guard_path,
                content=guard_content,
            ),
            RunSubprocess(
                effect_id="check_code_policy_guard",
                description="Enforce Poetry entrypoint policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.no_direct_poetry_run_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_skip_guard",
                description="Enforce no-skip/xfail test policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.no_test_skip_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_purity_guard",
                description="Enforce interpreter-bound purity policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.purity_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_no_statements_guard",
                description="Evaluate no-statements policy rollout",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.no_statements_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_shell_guard",
                description="Enforce no-shell invocation policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.no_shell_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_threading_guard",
                description="Enforce no-threading policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.no_threading_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_type_escape_guard",
                description="Enforce type-escape policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.type_escape_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_command_collision_guard",
                description="Enforce command-name collision policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.command_name_collision_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_timeout_guard",
                description="Enforce timeout policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.timeout_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_doc_lint_guard",
                description="Enforce documentation lint policy",
                command=[
                    sys.executable,
                    "-m",
                    "prodbox.lib.lint.doc_lint_guard",
                ],
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_ruff_check",
                description="Lint with ruff",
                command=ruff_check_command,
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_ruff_format_check",
                description="Verify formatting with ruff format",
                command=ruff_format_command,
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
            RunSubprocess(
                effect_id="check_code_mypy",
                description="Type check with mypy",
                command=mypy_command,
                stream_stdout=True,
                timeout=CHECK_CODE_TIMEOUT_SECONDS,
                env=allow_env,
            ),
        ],
    )
    return execute_effect(effects)
