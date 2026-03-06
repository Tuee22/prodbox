"""Unit tests for the `prodbox check-code` command."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

from click.testing import CliRunner

from prodbox.cli.check_code import CHECK_CODE_TIMEOUT_SECONDS, _run_check_code, check_code
from prodbox.cli.effects import RunSubprocess, Sequence, WriteFile, WriteStdout
from prodbox.cli.main import cli
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV


def test_run_check_code_builds_expected_sequence() -> None:
    """_run_check_code should build an exec-mode Sequence with expected commands."""
    captured: dict[str, object] = {}

    def _capture_effect(effect: object) -> int:
        captured["effect"] = effect
        return 0

    with patch("prodbox.cli.check_code.execute_effect", side_effect=_capture_effect):
        exit_code = _run_check_code()

    assert exit_code == 0
    effect = captured["effect"]
    assert isinstance(effect, Sequence)
    assert effect.effect_id == "check_code_sequence"
    assert isinstance(effect.effects[0], WriteStdout)
    assert isinstance(effect.effects[1], WriteFile)

    subprocess_effects = [item for item in effect.effects if isinstance(item, RunSubprocess)]
    assert [item.effect_id for item in subprocess_effects] == [
        "check_code_policy_guard",
        "check_code_ruff_check",
        "check_code_ruff_format_check",
        "check_code_mypy",
    ]
    policy_command = subprocess_effects[0].command
    assert policy_command[0] == sys.executable
    assert policy_command[1:] == ["-m", "prodbox.lib.lint.no_direct_poetry_run_guard"]

    ruff_check_command = subprocess_effects[1].command
    assert Path(ruff_check_command[0]).name == "ruff"
    assert ruff_check_command[1:] == ["check", "src/", "tests/"]

    ruff_format_command = subprocess_effects[2].command
    assert Path(ruff_format_command[0]).name == "ruff"
    assert ruff_format_command[1:] == ["format", "--check", "src/", "tests/"]

    mypy_command = subprocess_effects[3].command
    assert Path(mypy_command[0]).name == "mypy"
    assert mypy_command[1:] == ["src/"]

    for item in subprocess_effects:
        assert item.stream_stdout is True
        assert item.timeout == CHECK_CODE_TIMEOUT_SECONDS
        assert item.env is not None
        assert item.env.get(ALLOW_NON_ENTRYPOINT_ENV) == "1"


def test_check_code_command_exits_with_internal_result() -> None:
    """Click command should exit with _run_check_code result."""
    runner = CliRunner()

    with patch("prodbox.cli.check_code._run_check_code", return_value=0) as mock_run:
        result = runner.invoke(check_code, [])

    assert result.exit_code == 0
    mock_run.assert_called_once()


def test_check_code_is_registered_on_main_cli() -> None:
    """Main prodbox CLI should expose check-code as a top-level command."""
    runner = CliRunner()

    with patch("prodbox.cli.check_code._run_check_code", return_value=0) as mock_run:
        result = runner.invoke(cli, ["check-code"])

    assert result.exit_code == 0
    mock_run.assert_called_once()
