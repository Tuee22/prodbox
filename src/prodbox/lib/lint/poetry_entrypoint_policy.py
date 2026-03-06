"""Shared helpers for Poetry entrypoint policy enforcement."""

from __future__ import annotations

import re
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import TypeGuard

_POETRY_RUN_PATTERN = re.compile(r"\bpoetry\s+run\s+([A-Za-z0-9_.-]+)\b")


@dataclass(frozen=True)
class EntryPointPolicy:
    """Loaded entrypoint policy for Poetry commands."""

    allowed_entrypoints: frozenset[str]
    pyproject_path: Path


def repo_root() -> Path:
    """Return repository root based on this module's path."""
    return Path(__file__).resolve().parents[4]


def default_pyproject_path() -> Path:
    """Return default pyproject.toml path for this repo."""
    return repo_root() / "pyproject.toml"


def load_entrypoint_policy(pyproject_path: Path) -> EntryPointPolicy:
    """Load allowed Poetry entrypoints from pyproject.toml."""
    raw: object = tomllib.loads(pyproject_path.read_text(encoding="utf-8"))
    data = _as_mapping(raw)
    tool = _get_mapping(data, "tool")
    poetry = _get_mapping(tool, "poetry")
    scripts_raw = _get_mapping(poetry, "scripts")
    scripts = _as_mapping_str_str(scripts_raw)
    return EntryPointPolicy(
        allowed_entrypoints=frozenset(scripts.keys()),
        pyproject_path=pyproject_path,
    )


def parse_poetry_run_command(line: str) -> str | None:
    """Extract the `poetry run <command>` token from a line."""
    match _POETRY_RUN_PATTERN.search(line):
        case None:
            return None
        case match_obj:
            return match_obj.group(1)


def _get_mapping(
    data: Mapping[str, object] | None,
    key: str,
) -> Mapping[str, object] | None:
    """Get a nested mapping value by key."""
    match data:
        case None:
            return None
        case _:
            return _as_mapping(data.get(key))


def _as_mapping(value: object) -> Mapping[str, object] | None:
    """Return value as Mapping[str, object] if possible."""
    return value if _is_mapping_str_object(value) else None


def _as_mapping_str_str(value: object) -> Mapping[str, str]:
    """Return value as Mapping[str, str] or empty mapping."""
    return value if _is_mapping_str_str(value) else {}


def _is_mapping_str_object(value: object) -> TypeGuard[Mapping[str, object]]:
    """Check value is a mapping of string keys to object values."""
    return isinstance(value, Mapping) and all(isinstance(key, str) for key in value)


def _is_mapping_str_str(value: object) -> TypeGuard[Mapping[str, str]]:
    """Check value is a mapping of string keys to string values."""
    return isinstance(value, Mapping) and all(
        isinstance(key, str) and isinstance(val, str) for key, val in value.items()
    )
