"""Async subprocess execution utilities."""

from __future__ import annotations

import asyncio
import builtins
import os
from collections.abc import Mapping
from dataclasses import dataclass

from prodbox.lib.exceptions import CommandError, TimeoutError


@dataclass(frozen=True)
class CommandResult:
    """Immutable result from a subprocess execution.

    Attributes:
        returncode: Exit code from the process.
        stdout: Captured standard output.
        stderr: Captured standard error.
        command: The command string that was executed.
    """

    returncode: int
    stdout: str
    stderr: str
    command: str

    @property
    def success(self) -> bool:
        """Check if command succeeded (returncode == 0)."""
        return self.returncode == 0

    def raise_on_error(self) -> CommandResult:
        """Raise CommandError if the command failed, otherwise return self."""
        match self.success:
            case True:
                return self
            case False:
                raise CommandError(f"Command failed: {self.command}", self)


async def run_command(
    command: list[str],
    *,
    check: bool = True,
    timeout: float | None = None,
    env: Mapping[str, str] | None = None,
    cwd: str | None = None,
    input_data: bytes | None = None,
) -> CommandResult:
    """Run a command as an async subprocess.

    Args:
        command: Command and arguments as a list of strings.
        check: Raise CommandError on non-zero exit code.
        timeout: Maximum execution time in seconds.
        env: Environment variables to pass to the subprocess.
        cwd: Working directory for the subprocess.
        input_data: Data to send to stdin.

    Returns:
        CommandResult with captured output.

    Raises:
        CommandError: If check=True and the command returns non-zero.
        TimeoutError: If the command exceeds the timeout.
    """
    merged_env: dict[str, str] | None = None
    match env:
        case None:
            merged_env = None
        case mapping:
            merged_env = {**os.environ, **mapping}

    command_str = " ".join(command)

    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            stdin=asyncio.subprocess.PIPE if input_data is not None else None,
            env=merged_env,
            cwd=cwd,
        )

        # asyncio.wait_for returns Coroutine[Any, Any, T] — unavoidable stdlib Any
        stdout_bytes, stderr_bytes = await asyncio.wait_for(  # type: ignore[misc]
            process.communicate(input=input_data),
            timeout=timeout,
        )

        result = CommandResult(
            returncode=process.returncode if process.returncode is not None else -1,
            stdout=stdout_bytes.decode() if stdout_bytes else "",
            stderr=stderr_bytes.decode() if stderr_bytes else "",
            command=command_str,
        )

        match (check, result.success):
            case (True, False):
                raise CommandError(f"Command failed: {command_str}", result)
            case _:
                return result

    except builtins.TimeoutError:
        process.kill()
        await process.wait()
        raise TimeoutError(f"Command timed out after {timeout}s: {command_str}") from None


async def run_shell(
    command: str,
    *,
    check: bool = True,
    timeout: float | None = None,
    env: Mapping[str, str] | None = None,
    cwd: str | None = None,
) -> CommandResult:
    """Run a shell command as an async subprocess.

    Args:
        command: Shell command string.
        check: Raise CommandError on non-zero exit code.
        timeout: Maximum execution time in seconds.
        env: Environment variables to pass to the subprocess.
        cwd: Working directory for the subprocess.

    Returns:
        CommandResult with captured output.

    Raises:
        CommandError: If check=True and the command returns non-zero.
        TimeoutError: If the command exceeds the timeout.
    """
    merged_env: dict[str, str] | None = None
    match env:
        case None:
            merged_env = None
        case mapping:
            merged_env = {**os.environ, **mapping}

    try:
        process = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=merged_env,
            cwd=cwd,
        )

        # asyncio.wait_for returns Coroutine[Any, Any, T] — unavoidable stdlib Any
        stdout_bytes, stderr_bytes = await asyncio.wait_for(  # type: ignore[misc]
            process.communicate(),
            timeout=timeout,
        )

        result = CommandResult(
            returncode=process.returncode if process.returncode is not None else -1,
            stdout=stdout_bytes.decode() if stdout_bytes else "",
            stderr=stderr_bytes.decode() if stderr_bytes else "",
            command=command,
        )

        match (check, result.success):
            case (True, False):
                raise CommandError(f"Command failed: {command}", result)
            case _:
                return result

    except builtins.TimeoutError:
        process.kill()
        await process.wait()
        raise TimeoutError(f"Command timed out after {timeout}s: {command}") from None
