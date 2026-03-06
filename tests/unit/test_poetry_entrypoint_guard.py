"""Unit tests for runtime Poetry entrypoint guard."""

from __future__ import annotations

from pathlib import Path

import pytest

from prodbox.lib.lint.poetry_entrypoint_guard import (
    ALLOW_NON_ENTRYPOINT_ENV,
    enforce_entrypoint_policy,
)


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def test_guard_allows_entrypoint(tmp_path: Path) -> None:
    pyproject = tmp_path / "pyproject.toml"
    _write(
        pyproject,
        "\n".join(
            [
                "[tool.poetry.scripts]",
                'prodbox = "prodbox.cli.main:main"',
                "",
            ]
        ),
    )
    enforce_entrypoint_policy(
        pyproject_path=pyproject,
        command_name="prodbox",
        exit_mode="raise",
    )


def test_guard_blocks_non_entrypoint(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pyproject = tmp_path / "pyproject.toml"
    _write(
        pyproject,
        "\n".join(
            [
                "[tool.poetry.scripts]",
                'prodbox = "prodbox.cli.main:main"',
                "",
            ]
        ),
    )
    # `prodbox test` sets this env var for pytest subprocess startup; clear it so this
    # unit test validates the default blocked-path behavior deterministically.
    monkeypatch.delenv(ALLOW_NON_ENTRYPOINT_ENV, raising=False)
    with pytest.raises(SystemExit):
        enforce_entrypoint_policy(
            pyproject_path=pyproject,
            command_name="mypy",
            exit_mode="raise",
        )


def test_guard_respects_allow_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pyproject = tmp_path / "pyproject.toml"
    _write(
        pyproject,
        "\n".join(
            [
                "[tool.poetry.scripts]",
                'prodbox = "prodbox.cli.main:main"',
                "",
            ]
        ),
    )
    monkeypatch.setenv(ALLOW_NON_ENTRYPOINT_ENV, "1")
    enforce_entrypoint_policy(
        pyproject_path=pyproject,
        command_name="mypy",
        exit_mode="raise",
    )
