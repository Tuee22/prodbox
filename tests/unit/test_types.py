"""Unit tests for CLI types module."""

from __future__ import annotations

import pytest

from prodbox.cli.types import (
    CommandFailure,
    CommandSuccess,
    Failure,
    Result,
    SubprocessResult,
    Success,
    failure,
    success,
)


class TestSuccess:
    """Tests for Success result type."""

    def test_success_holds_value(self) -> None:
        """Success should hold the provided value."""
        result: Success[int] = Success(42)
        assert result.value == 42

    def test_success_is_success_true(self) -> None:
        """Success.is_success should return True."""
        result = Success("test")
        assert result.is_success is True

    def test_success_is_failure_false(self) -> None:
        """Success.is_failure should return False."""
        result = Success("test")
        assert result.is_failure is False

    def test_success_is_frozen(self) -> None:
        """Success should be immutable."""
        result = Success("test")
        with pytest.raises(AttributeError):
            result.value = "modified"  # type: ignore[misc]

    def test_success_equality(self) -> None:
        """Two Success with same value should be equal."""
        assert Success(42) == Success(42)
        assert Success("test") == Success("test")

    def test_success_inequality(self) -> None:
        """Two Success with different values should not be equal."""
        assert Success(42) != Success(43)


class TestFailure:
    """Tests for Failure result type."""

    def test_failure_holds_error(self) -> None:
        """Failure should hold the provided error."""
        result: Failure[str] = Failure("error message")
        assert result.error == "error message"

    def test_failure_is_success_false(self) -> None:
        """Failure.is_success should return False."""
        result = Failure("error")
        assert result.is_success is False

    def test_failure_is_failure_true(self) -> None:
        """Failure.is_failure should return True."""
        result = Failure("error")
        assert result.is_failure is True

    def test_failure_is_frozen(self) -> None:
        """Failure should be immutable."""
        result = Failure("error")
        with pytest.raises(AttributeError):
            result.error = "modified"  # type: ignore[misc]

    def test_failure_equality(self) -> None:
        """Two Failure with same error should be equal."""
        assert Failure("error") == Failure("error")

    def test_failure_inequality(self) -> None:
        """Two Failure with different errors should not be equal."""
        assert Failure("error1") != Failure("error2")


class TestResultPatternMatching:
    """Tests for Result pattern matching."""

    def test_match_success(self) -> None:
        """Pattern matching should extract Success value."""
        result: Result[int, str] = Success(42)

        match result:
            case Success(value):
                assert value == 42
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_match_failure(self) -> None:
        """Pattern matching should extract Failure error."""
        result: Result[int, str] = Failure("error")

        match result:
            case Success(value):
                pytest.fail(f"Expected Failure, got Success: {value}")
            case Failure(error):
                assert error == "error"


class TestHelperFunctions:
    """Tests for helper functions."""

    def test_success_helper(self) -> None:
        """success() should create Success."""
        result = success(42)
        assert isinstance(result, Success)
        assert result.value == 42

    def test_failure_helper(self) -> None:
        """failure() should create Failure."""
        result = failure("error")
        assert isinstance(result, Failure)
        assert result.error == "error"


class TestSubprocessResult:
    """Tests for SubprocessResult type."""

    def test_subprocess_result_fields(self) -> None:
        """SubprocessResult should hold all fields."""
        result = SubprocessResult(
            command=("echo", "hello"),
            returncode=0,
            stdout="hello\n",
            stderr="",
        )
        assert result.command == ("echo", "hello")
        assert result.returncode == 0
        assert result.stdout == "hello\n"
        assert result.stderr == ""

    def test_subprocess_result_success_zero(self) -> None:
        """SubprocessResult.success should be True for returncode 0."""
        result = SubprocessResult(
            command=("echo",),
            returncode=0,
        )
        assert result.success is True

    def test_subprocess_result_success_nonzero(self) -> None:
        """SubprocessResult.success should be False for non-zero returncode."""
        result = SubprocessResult(
            command=("false",),
            returncode=1,
        )
        assert result.success is False

    def test_subprocess_result_is_frozen(self) -> None:
        """SubprocessResult should be immutable."""
        result = SubprocessResult(command=("echo",), returncode=0)
        with pytest.raises(AttributeError):
            result.returncode = 1  # type: ignore[misc]

    def test_subprocess_result_default_values(self) -> None:
        """SubprocessResult should have default values for stdout/stderr."""
        result = SubprocessResult(command=("echo",), returncode=0)
        assert result.stdout == ""
        assert result.stderr == ""


class TestCommandSuccess:
    """Tests for CommandSuccess type."""

    def test_command_success_message(self) -> None:
        """CommandSuccess should hold message."""
        result = CommandSuccess(message="Operation completed")
        assert result.message == "Operation completed"

    def test_command_success_artifacts(self) -> None:
        """CommandSuccess should hold artifacts."""
        result = CommandSuccess(
            message="Created files",
            artifacts={"config": "/path/to/config", "log": "/path/to/log"},
        )
        assert result.artifacts is not None
        assert result.artifacts["config"] == "/path/to/config"

    def test_command_success_default_artifacts(self) -> None:
        """CommandSuccess artifacts should default to None."""
        result = CommandSuccess(message="Done")
        assert result.artifacts is None


class TestCommandFailure:
    """Tests for CommandFailure type."""

    def test_command_failure_message(self) -> None:
        """CommandFailure should hold message."""
        result = CommandFailure(message="Operation failed")
        assert result.message == "Operation failed"

    def test_command_failure_details(self) -> None:
        """CommandFailure should hold details."""
        result = CommandFailure(
            message="Failed",
            details=("Detail 1", "Detail 2"),
        )
        assert result.details == ("Detail 1", "Detail 2")

    def test_command_failure_fix_hint(self) -> None:
        """CommandFailure should hold fix_hint."""
        result = CommandFailure(
            message="Failed",
            fix_hint="Try running as root",
        )
        assert result.fix_hint == "Try running as root"

    def test_command_failure_returncode(self) -> None:
        """CommandFailure should hold returncode."""
        result = CommandFailure(
            message="Command exited with error",
            returncode=127,
        )
        assert result.returncode == 127

    def test_command_failure_defaults(self) -> None:
        """CommandFailure should have default None values."""
        result = CommandFailure(message="Failed")
        assert result.details is None
        assert result.fix_hint is None
        assert result.returncode is None
