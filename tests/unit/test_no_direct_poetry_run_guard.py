"""Unit tests for the no-direct-poetry-run policy guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.no_direct_poetry_run_guard import find_policy_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_guard_allows_entrypoint_poetry_run(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    _write(
        repo_root / "pyproject.toml",
        "\n".join(
            [
                "[tool.poetry.scripts]",
                'prodbox = "prodbox.cli.main:main"',
                'daemon = "prodbox.gateway_daemon:main"',
                "",
            ]
        ),
    )
    file_path = _write(repo_root / "README.md", "poetry run prodbox check-code\n")
    violations = find_policy_violations(
        repo_root,
        target_files=(file_path,),
    )
    assert violations == ()


def test_guard_flags_non_entrypoint_poetry_run(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    _write(
        repo_root / "pyproject.toml",
        "\n".join(
            [
                "[tool.poetry.scripts]",
                'prodbox = "prodbox.cli.main:main"',
                "",
            ]
        ),
    )
    file_path = _write(repo_root / "README.md", "poetry run mypy src/\n")
    violations = find_policy_violations(
        repo_root,
        target_files=(file_path,),
    )
    assert len(violations) == 1
    assert violations[0].command == "mypy"


def test_guard_ignores_non_command_lines(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    _write(
        repo_root / "pyproject.toml",
        "\n".join(
            [
                "[tool.poetry.scripts]",
                'prodbox = "prodbox.cli.main:main"',
                "",
            ]
        ),
    )
    file_path = _write(repo_root / "README.md", "Run poetry for dependency management.\n")
    violations = find_policy_violations(
        repo_root,
        target_files=(file_path,),
    )
    assert violations == ()
