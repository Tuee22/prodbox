"""Custom exceptions for prodbox."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from prodbox.lib.subprocess import CommandResult


class ProdboxError(Exception):
    """Base exception for all prodbox errors."""

    def __init__(self, message: str) -> None:
        self.message = message
        super().__init__(message)


class CommandError(ProdboxError):
    """Error raised when a command execution fails.

    Attributes:
        result: The CommandResult from the failed command, or None.
    """

    def __init__(self, message: str, result: CommandResult | None) -> None:
        self.result = result
        super().__init__(self._format_message(message, result))

    @staticmethod
    def _format_message(message: str, result: CommandResult | None) -> str:
        """Format error message with command result details."""
        match result:
            case None:
                return message
            case r if r.stderr:
                return (
                    f"{message}\n"
                    f"  Command: {r.command} (exit code {r.returncode})\n"
                    f"  Stderr: {r.stderr}"
                )
            case r:
                return f"{message}\n  Command: {r.command} (exit code {r.returncode})"


class TimeoutError(ProdboxError):
    """Error raised when an operation exceeds its timeout."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
