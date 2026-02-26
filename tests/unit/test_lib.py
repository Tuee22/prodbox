"""Unit tests for lib modules."""

from __future__ import annotations

import asyncio
from unittest.mock import MagicMock, patch

import pytest

from prodbox.lib.async_runner import async_command
from prodbox.lib.exceptions import CommandError, ProdboxError, TimeoutError
from prodbox.lib.logging import setup_logging


class TestProdboxError:
    """Tests for ProdboxError base exception."""

    def test_prodbox_error_message(self) -> None:
        """ProdboxError should hold message."""
        error = ProdboxError("Something went wrong")
        assert str(error) == "Something went wrong"

    def test_prodbox_error_is_exception(self) -> None:
        """ProdboxError should be an Exception."""
        error = ProdboxError("test")
        assert isinstance(error, Exception)


class TestCommandError:
    """Tests for CommandError exception."""

    def test_command_error_message(self) -> None:
        """CommandError should format message with command."""
        from prodbox.lib.subprocess import CommandResult

        result = CommandResult(
            returncode=1,
            stdout="",
            stderr="error output",
            command="failing command",
        )
        error = CommandError("Command failed", result)

        assert "Command failed" in str(error)
        assert error.result is result

    def test_command_error_is_prodbox_error(self) -> None:
        """CommandError should be a ProdboxError."""
        from prodbox.lib.subprocess import CommandResult

        result = CommandResult(
            returncode=1,
            stdout="",
            stderr="",
            command="test",
        )
        error = CommandError("test", result)

        assert isinstance(error, ProdboxError)

    def test_command_error_str_with_result(self) -> None:
        """CommandError str should include command and exit code."""
        from prodbox.lib.subprocess import CommandResult

        result = CommandResult(
            returncode=127,
            stdout="",
            stderr="command not found",
            command="nonexistent_cmd",
        )
        error = CommandError("Failed to run command", result)
        error_str = str(error)

        assert "nonexistent_cmd" in error_str
        assert "127" in error_str
        assert "command not found" in error_str

    def test_command_error_str_without_stderr(self) -> None:
        """CommandError str should work without stderr."""
        from prodbox.lib.subprocess import CommandResult

        result = CommandResult(
            returncode=1,
            stdout="output",
            stderr="",
            command="some_cmd",
        )
        error = CommandError("Failed", result)
        error_str = str(error)

        assert "some_cmd" in error_str
        assert "Stderr" not in error_str  # Should not include stderr section

    def test_command_error_str_without_result(self) -> None:
        """CommandError str should work without result."""
        error = CommandError("Simple error", None)
        error_str = str(error)

        assert "Simple error" in error_str
        assert "Command:" not in error_str


class TestTimeoutError:
    """Tests for TimeoutError exception."""

    def test_timeout_error_message(self) -> None:
        """TimeoutError should hold message."""
        error = TimeoutError("Operation timed out after 30s")
        assert "timed out" in str(error)

    def test_timeout_error_is_prodbox_error(self) -> None:
        """TimeoutError should be a ProdboxError."""
        error = TimeoutError("test")
        assert isinstance(error, ProdboxError)


class TestSetupLogging:
    """Tests for setup_logging function."""

    def test_setup_logging_default(self) -> None:
        """setup_logging should configure logging."""
        # Just verify it doesn't raise
        setup_logging()

    def test_setup_logging_debug(self) -> None:
        """setup_logging should accept DEBUG level."""
        setup_logging(level="DEBUG")

    def test_setup_logging_info(self) -> None:
        """setup_logging should accept INFO level."""
        setup_logging(level="INFO")

    def test_setup_logging_warning(self) -> None:
        """setup_logging should accept WARNING level."""
        setup_logging(level="WARNING")

    def test_setup_logging_error(self) -> None:
        """setup_logging should accept ERROR level."""
        setup_logging(level="ERROR")


class TestAsyncCommand:
    """Tests for async_command decorator."""

    def test_async_command_wraps_async_function(self) -> None:
        """async_command should wrap async functions."""

        @async_command
        async def my_async_func() -> str:
            return "hello"

        # The decorated function should be synchronous
        assert not asyncio.iscoroutinefunction(my_async_func)

    def test_async_command_runs_async_function(self) -> None:
        """async_command should run the async function."""
        result_holder: list[str] = []

        @async_command
        async def my_async_func() -> None:
            result_holder.append("executed")

        # Run the function
        my_async_func()

        assert result_holder == ["executed"]

    def test_async_command_returns_result(self) -> None:
        """async_command should return the async function's result."""

        @async_command
        async def my_async_func() -> int:
            return 42

        result = my_async_func()
        assert result == 42

    def test_async_command_preserves_args(self) -> None:
        """async_command should pass arguments to async function."""

        @async_command
        async def my_async_func(a: int, b: str) -> str:
            return f"{a}-{b}"

        result = my_async_func(1, "test")
        assert result == "1-test"

    def test_async_command_preserves_kwargs(self) -> None:
        """async_command should pass keyword arguments to async function."""

        @async_command
        async def my_async_func(*, name: str) -> str:
            return f"hello {name}"

        result = my_async_func(name="world")
        assert result == "hello world"


class TestRunWithTimeout:
    """Tests for run_with_timeout function."""

    @pytest.mark.asyncio
    async def test_run_with_timeout_success(self) -> None:
        """run_with_timeout should return result when fast."""
        from prodbox.lib.async_runner import run_with_timeout

        async def fast_coro() -> str:
            return "done"

        result = await run_with_timeout(fast_coro(), timeout=5.0)
        assert result == "done"

    @pytest.mark.asyncio
    async def test_run_with_timeout_raises_on_timeout(self) -> None:
        """run_with_timeout should raise TimeoutError on timeout."""
        from prodbox.lib.async_runner import run_with_timeout

        async def slow_coro() -> str:
            await asyncio.sleep(10)
            return "never"

        with pytest.raises(TimeoutError, match="Timed out"):
            await run_with_timeout(
                slow_coro(),
                timeout=0.01,
                message="Timed out",
            )


class TestPrintHelpers:
    """Tests for print helper functions."""

    def test_print_success_outputs(self) -> None:
        """print_success should output with green formatting."""
        from prodbox.lib.logging import print_success

        with patch("prodbox.lib.logging.console") as mock_console:
            print_success("Done!")
            mock_console.print.assert_called_once()
            call_arg: str = mock_console.print.call_args[0][0]
            assert "green" in call_arg
            assert "Done!" in call_arg

    def test_print_error_outputs(self) -> None:
        """print_error should output with red formatting to stderr."""
        from prodbox.lib.logging import print_error

        with patch("prodbox.lib.logging.error_console") as mock_console:
            print_error("Failed!")
            mock_console.print.assert_called_once()
            call_arg: str = mock_console.print.call_args[0][0]
            assert "red" in call_arg
            assert "Failed!" in call_arg

    def test_print_warning_outputs(self) -> None:
        """print_warning should output with yellow formatting."""
        from prodbox.lib.logging import print_warning

        with patch("prodbox.lib.logging.console") as mock_console:
            print_warning("Careful!")
            mock_console.print.assert_called_once()
            call_arg: str = mock_console.print.call_args[0][0]
            assert "yellow" in call_arg
            assert "Careful!" in call_arg

    def test_print_info_outputs(self) -> None:
        """print_info should output with blue formatting."""
        from prodbox.lib.logging import print_info

        with patch("prodbox.lib.logging.console") as mock_console:
            print_info("Note:")
            mock_console.print.assert_called_once()
            call_arg: str = mock_console.print.call_args[0][0]
            assert "blue" in call_arg
            assert "Note:" in call_arg


class TestRunShell:
    """Tests for run_shell function."""

    @pytest.mark.asyncio
    async def test_run_shell_success(self) -> None:
        """run_shell should return result for successful command."""
        from prodbox.lib.subprocess import run_shell

        result = await run_shell("echo hello")
        assert result.success
        assert "hello" in result.stdout

    @pytest.mark.asyncio
    async def test_run_shell_failure(self) -> None:
        """run_shell should return failure for failing command when check=False."""
        from prodbox.lib.subprocess import run_shell

        result = await run_shell("exit 1", check=False)
        assert not result.success
        assert result.returncode == 1

    @pytest.mark.asyncio
    async def test_run_shell_timeout(self) -> None:
        """run_shell should raise TimeoutError on timeout."""
        from prodbox.lib.subprocess import run_shell

        with pytest.raises(TimeoutError, match="timed out"):
            await run_shell("sleep 10", timeout=0.1)

    @pytest.mark.asyncio
    async def test_run_shell_with_env(self) -> None:
        """run_shell should pass environment variables."""
        from prodbox.lib.subprocess import run_shell

        result = await run_shell("echo $TEST_VAR", env={"TEST_VAR": "hello123"})
        assert result.success
        assert "hello123" in result.stdout

    @pytest.mark.asyncio
    async def test_run_shell_with_check_raises(self) -> None:
        """run_shell with check=True should raise on failure."""
        from prodbox.lib.subprocess import run_shell
        from prodbox.lib.exceptions import CommandError

        with pytest.raises(CommandError):
            await run_shell("exit 1", check=True)


class TestConcurrencyEdgeCases:
    """Tests for concurrency module edge cases."""

    @pytest.mark.asyncio
    async def test_first_success_returns_first(self) -> None:
        """first_success should return first successful result."""
        from prodbox.lib.concurrency import first_success

        async def fast() -> str:
            return "fast"

        async def slow() -> str:
            await asyncio.sleep(10)
            return "slow"

        result = await first_success([fast(), slow()])
        assert result == "fast"

    @pytest.mark.asyncio
    async def test_first_success_all_fail(self) -> None:
        """first_success should raise when all fail."""
        from prodbox.lib.concurrency import first_success

        async def fail1() -> str:
            raise ValueError("fail1")

        async def fail2() -> str:
            raise ValueError("fail2")

        with pytest.raises(ValueError):
            await first_success([fail1(), fail2()])

    @pytest.mark.asyncio
    async def test_first_success_timeout(self) -> None:
        """first_success should raise TimeoutError on timeout."""
        from prodbox.lib.concurrency import first_success

        async def very_slow() -> str:
            await asyncio.sleep(100)
            return "never"

        with pytest.raises(TimeoutError, match="Timeout"):
            await first_success([very_slow()], timeout=0.01)

    @pytest.mark.asyncio
    async def test_first_success_cancelled_task_handling(self) -> None:
        """first_success should skip cancelled tasks in done set."""
        import asyncio
        from prodbox.lib.concurrency import first_success

        async def quick_success() -> str:
            return "success"

        async def slow_that_gets_cancelled() -> str:
            await asyncio.sleep(10)
            return "never"

        # Run with both - the quick one should succeed and the slow one get cancelled
        result = await first_success([quick_success(), slow_that_gets_cancelled()])
        assert result == "success"

    @pytest.mark.asyncio
    async def test_first_success_empty_list(self) -> None:
        """first_success with empty list should raise ValueError from asyncio."""
        from prodbox.lib.concurrency import first_success

        # asyncio.wait raises ValueError for empty set
        with pytest.raises(ValueError, match="empty"):
            await first_success([])


class TestWaitAll:
    """Tests for wait_all function."""

    @pytest.mark.asyncio
    async def test_wait_all_success(self) -> None:
        """wait_all should return all results when all succeed."""
        from prodbox.lib.concurrency import wait_all

        async def task1() -> int:
            return 1

        async def task2() -> int:
            return 2

        results = await wait_all([task1(), task2()])
        assert set(results) == {1, 2}

    @pytest.mark.asyncio
    async def test_wait_all_failure(self) -> None:
        """wait_all should raise when any task fails."""
        from prodbox.lib.concurrency import wait_all

        async def success() -> int:
            return 1

        async def fail() -> int:
            raise ValueError("failed")

        with pytest.raises(ValueError, match="failed"):
            await wait_all([success(), fail()])

    @pytest.mark.asyncio
    async def test_wait_all_timeout(self) -> None:
        """wait_all should raise TimeoutError on timeout."""
        from prodbox.lib.concurrency import wait_all

        async def slow() -> int:
            await asyncio.sleep(10)
            return 1

        with pytest.raises(TimeoutError):
            await wait_all([slow()], timeout=0.01)
