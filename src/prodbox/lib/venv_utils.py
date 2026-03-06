"""Virtualenv tool resolution utilities for prodbox."""

from __future__ import annotations

import os
import shutil
from pathlib import Path

__all__ = ["build_tool_command", "get_virtualenv_tool_path"]


def get_virtualenv_tool_path(tool_name: str) -> str:
    """Resolve an executable path, preferring the active virtualenv.

    Args:
        tool_name: Tool executable name (e.g., "mypy", "ruff", "pytest")

    Returns:
        Absolute tool path if found, otherwise the tool name as a fallback.
    """
    venv_path = os.environ.get("VIRTUAL_ENV")
    match venv_path:
        case str() as venv_str:
            candidate = Path(venv_str) / "bin" / tool_name
            return str(candidate) if candidate.is_file() else _fallback_tool_path(tool_name)
        case _:
            return _fallback_tool_path(tool_name)


def _fallback_tool_path(tool_name: str) -> str:
    """Fallback to PATH lookup or return the tool name."""
    resolved = shutil.which(tool_name)
    return resolved if resolved is not None else tool_name


def build_tool_command(tool_name: str, args: tuple[str, ...]) -> list[str]:
    """Build an exec-mode command for a virtualenv-installed tool."""
    tool_path = get_virtualenv_tool_path(tool_name)
    return [tool_path, *args]
