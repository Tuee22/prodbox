"""Unit tests for subprocess utilities."""

from __future__ import annotations

import pytest

from prodbox.lib.subprocess import run_command, CommandResult
from prodbox.lib.exceptions import CommandError, TimeoutError


class TestCommandResult:
    """Tests for CommandResult dataclass."""

    def test_success_when_returncode_zero(self) -> None:
        """success should be True when returncode is 0."""
        result = CommandResult(
            returncode=0,
            stdout="output",
            stderr="",
            command="echo hello",
        )
        assert result.success is True

    def test_success_when_returncode_nonzero(self) -> None:
        """success should be False when returncode is non-zero."""
        result = CommandResult(
            returncode=1,
            stdout="",
            stderr="error",
            command="false",
        )
        assert result.success is False

    def test_raise_on_error_passes_when_successful(self) -> None:
        """raise_on_error should return self when successful."""
        result = CommandResult(
            returncode=0,
            stdout="output",
            stderr="",
            command="echo hello",
        )
        assert result.raise_on_error() is result

    def test_raise_on_error_raises_when_failed(self) -> None:
        """raise_on_error should raise CommandError when failed."""
        result = CommandResult(
            returncode=1,
            stdout="",
            stderr="error message",
            command="failing command",
        )
        with pytest.raises(CommandError) as exc_info:
            result.raise_on_error()

        assert exc_info.value.result is result
        assert "failing command" in str(exc_info.value)


class TestRunCommand:
    """Tests for run_command function."""

    @pytest.mark.asyncio
    async def test_captures_stdout(self) -> None:
        """run_command should capture stdout."""
        result = await run_command(["echo", "hello world"])

        assert result.success
        assert result.stdout.strip() == "hello world"
        assert result.stderr == ""

    @pytest.mark.asyncio
    async def test_captures_stderr(self) -> None:
        """run_command should capture stderr."""
        result = await run_command(
            ["sh", "-c", "echo error >&2"],
            check=False,
        )

        assert result.stderr.strip() == "error"

    @pytest.mark.asyncio
    async def test_returns_exit_code(self) -> None:
        """run_command should return the exit code."""
        result = await run_command(["sh", "-c", "exit 42"], check=False)

        assert result.returncode == 42
        assert not result.success

    @pytest.mark.asyncio
    async def test_raises_on_failure_when_check_true(self) -> None:
        """run_command should raise CommandError when check=True and command fails."""
        with pytest.raises(CommandError):
            await run_command(["false"])

    @pytest.mark.asyncio
    async def test_no_raise_when_check_false(self) -> None:
        """run_command should not raise when check=False."""
        result = await run_command(["false"], check=False)

        assert not result.success
        assert result.returncode == 1

    @pytest.mark.asyncio
    async def test_timeout_raises_error(self) -> None:
        """run_command should raise TimeoutError when timeout exceeded."""
        with pytest.raises(TimeoutError):
            await run_command(
                ["sleep", "10"],
                timeout=0.1,
            )

    @pytest.mark.asyncio
    async def test_stores_command_string(self) -> None:
        """run_command should store the command string."""
        result = await run_command(["echo", "hello", "world"])

        assert result.command == "echo hello world"

    @pytest.mark.asyncio
    async def test_with_environment_variables(self) -> None:
        """run_command should pass environment variables."""
        result = await run_command(
            ["sh", "-c", "echo $TEST_VAR"],
            env={"TEST_VAR": "test_value"},
        )

        assert result.stdout.strip() == "test_value"

    @pytest.mark.asyncio
    async def test_with_working_directory(self) -> None:
        """run_command should use the specified working directory."""
        result = await run_command(
            ["pwd"],
            cwd="/tmp",
        )

        assert result.stdout.strip() == "/tmp"

    @pytest.mark.asyncio
    async def test_with_input_data(self) -> None:
        """run_command should send input data to stdin."""
        result = await run_command(
            ["cat"],
            input_data=b"hello from stdin",
        )

        assert result.stdout == "hello from stdin"
