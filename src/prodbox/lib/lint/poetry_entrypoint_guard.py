"""Runtime guard that blocks non-entrypoint Poetry commands."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Literal

from prodbox.lib.lint.poetry_entrypoint_policy import default_pyproject_path, load_entrypoint_policy

ALLOW_NON_ENTRYPOINT_ENV = "PRODBOX_ALLOW_NON_ENTRYPOINT"
ALWAYS_ALLOW_COMMANDS: frozenset[str] = frozenset({"-c"})


def enforce_entrypoint_policy(
    *,
    pyproject_path: Path | None = None,
    command_name: str | None = None,
    exit_mode: Literal["exit", "raise"] = "exit",
) -> None:
    """Exit if the current command is not an allowed Poetry entrypoint."""
    if _allow_non_entrypoint():
        return

    policy_path = pyproject_path if pyproject_path is not None else default_pyproject_path()
    policy = load_entrypoint_policy(policy_path)
    allowed = policy.allowed_entrypoints
    match command_name:
        case None:
            current = _current_command_name()
        case str() as value:
            current = value

    if not current or current in allowed or current in ALWAYS_ALLOW_COMMANDS:
        return

    _render_blocked_command(current, allowed)
    _exit_blocked(exit_mode)


def _allow_non_entrypoint() -> bool:
    """Return True if the guard is explicitly bypassed."""
    match os.environ.get(ALLOW_NON_ENTRYPOINT_ENV):
        case "1" | "true" | "TRUE":
            return True
        case _:
            return False


def _current_command_name() -> str:
    """Return the current command name derived from argv[0]."""
    match sys.argv:
        case [first, *_]:
            return Path(first).name
        case _:
            return ""


def _render_blocked_command(command: str, allowed: frozenset[str]) -> None:
    """Print a clear error message for blocked commands."""
    allowed_list = ", ".join(sorted(allowed)) if allowed else "(none)"
    message = (
        "Entry-point policy violation: direct tool execution is forbidden.\n"
        f"Command: {command}\n"
        f"Allowed Poetry entrypoints: {allowed_list}\n"
        "Use `poetry run prodbox <command>` instead."
    )
    print(message, file=sys.stderr)


def _exit_blocked(exit_mode: Literal["exit", "raise"]) -> None:
    """Terminate execution for blocked commands."""
    match exit_mode:
        case "raise":
            raise SystemExit(1)
        case _:
            sys.stderr.flush()
            os._exit(1)
