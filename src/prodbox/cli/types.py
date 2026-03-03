"""
Algebraic Data Types for prodbox CLI.

Provides Result types and common data structures following functional
programming principles and railway-oriented programming patterns.

Key types:
- Success[T] / Failure[E]: Result ADT for error handling without exceptions
- SubprocessResult: Immutable result from subprocess execution
- CommandSuccess / CommandFailure: CLI command outcome types
- PrereqResults: Mapping of prerequisite effect_ids to their results
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING, Generic, Protocol, TypeVar, Union

if TYPE_CHECKING:
    from prodbox.cli.effects import Effect

# Generic type variables for Result ADT
T = TypeVar("T")
E = TypeVar("E")


# =============================================================================
# Protocol Types
# =============================================================================


class InterpreterProtocol(Protocol):
    """
    Protocol for effect interpreter interface.

    Defines the minimal interface required by workflow functions. Both
    EffectInterpreter and test mocks satisfy this protocol, enabling
    type-safe testing without type-ignore comments.
    """

    async def interpret(self, effect: Effect[object]) -> object:
        """
        Interpret and execute an effect.

        Args:
            effect: Effect specification to execute

        Returns:
            Result of effect execution (type varies by effect)
        """
        ...


# =============================================================================
# Result ADT - Railway Oriented Programming
# =============================================================================


@dataclass(frozen=True)
class Success(Generic[T]):
    """
    Success variant of Result ADT.

    Represents a successful computation with a value of type T.
    Used in railway-oriented programming for composable error handling.

    Example:
        def parse_int(s: str) -> Result[int, str]:
            try:
                return Success(int(s))
            except ValueError:
                return Failure(f"Invalid integer: {s}")
    """

    value: T

    @property
    def is_success(self) -> bool:
        """Check if this is a success result."""
        return True

    @property
    def is_failure(self) -> bool:
        """Check if this is a failure result."""
        return False


@dataclass(frozen=True)
class Failure(Generic[E]):
    """
    Failure variant of Result ADT.

    Represents a failed computation with an error of type E.
    Used in railway-oriented programming for composable error handling.

    Example:
        def divide(a: int, b: int) -> Result[float, str]:
            if b == 0:
                return Failure("Division by zero")
            return Success(a / b)
    """

    error: E

    @property
    def is_success(self) -> bool:
        """Check if this is a success result."""
        return False

    @property
    def is_failure(self) -> bool:
        """Check if this is a failure result."""
        return True


# Result type alias - union of Success and Failure
Result = Union[Success[T], Failure[E]]  # noqa: UP007


# =============================================================================
# Subprocess Result Types
# =============================================================================


@dataclass(frozen=True)
class SubprocessResult:
    """
    Immutable result from subprocess execution.

    Captures all relevant information from a subprocess invocation:
    command, return code, and output streams.

    Attributes:
        command: The command that was executed (as string list)
        returncode: Exit code from the process
        stdout: Standard output (may be empty if not captured)
        stderr: Standard error (may be empty if not captured)
    """

    command: tuple[str, ...]
    returncode: int
    stdout: str = ""
    stderr: str = ""

    @property
    def success(self) -> bool:
        """Check if command succeeded (returncode == 0)."""
        return self.returncode == 0


# =============================================================================
# Command Outcome Types
# =============================================================================


@dataclass(frozen=True)
class CommandSuccess:
    """
    Successful command outcome with optional message and artifacts.

    Used to represent successful CLI command completion with
    contextual information about what was accomplished.

    Attributes:
        message: Human-readable success message
        artifacts: Optional mapping of artifact names to paths/values
    """

    message: str
    artifacts: Mapping[str, str] | None = None


@dataclass(frozen=True)
class CommandFailure:
    """
    Failed command outcome with error details.

    Used to represent CLI command failures with actionable
    error information for the user.

    Attributes:
        message: Human-readable error message
        details: Optional list of additional error details
        fix_hint: Optional hint for how to fix the issue
        returncode: Optional exit code if from subprocess
    """

    message: str
    details: tuple[str, ...] | None = None
    fix_hint: str | None = None
    returncode: int | None = None


# =============================================================================
# Prerequisite Result Types
# =============================================================================


# Type alias for prerequisite results mapping
# Maps effect_id strings to their Result values
PrereqResults = Mapping[str, Result[object, object]]


# =============================================================================
# Helper Functions
# =============================================================================


def success(value: T) -> Success[T]:
    """Create a Success result with the given value."""
    return Success(value)


def failure(error: E) -> Failure[E]:
    """Create a Failure result with the given error."""
    return Failure(error)


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    # Result ADT
    "Success",
    "Failure",
    "Result",
    "success",
    "failure",
    # Subprocess types
    "SubprocessResult",
    # Command types
    "CommandSuccess",
    "CommandFailure",
    # Prerequisite types
    "PrereqResults",
    # Protocols
    "InterpreterProtocol",
]
