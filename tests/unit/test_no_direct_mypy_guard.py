"""Unit tests for direct-mypy policy guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.no_direct_mypy_guard import find_policy_violations


def _write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def test_guard_detects_poetry_run_mypy(tmp_path: Path) -> None:
    """Guard should detect direct poetry-run mypy invocation."""
    repo_root = tmp_path
    file_path = _write(repo_root / "README.md", "poetry run mypy src/\n")

    violations = find_policy_violations(repo_root, target_files=(file_path,))

    assert len(violations) == 1
    violation = violations[0]
    assert violation.relative_path == Path("README.md")
    assert violation.line_number == 1


def test_guard_detects_bare_mypy_command(tmp_path: Path) -> None:
    """Guard should detect bare mypy command invocations."""
    repo_root = tmp_path
    file_path = _write(repo_root / "AGENTS.md", "mypy src/\n")

    violations = find_policy_violations(repo_root, target_files=(file_path,))

    assert len(violations) == 1
    assert violations[0].relative_path == Path("AGENTS.md")


def test_guard_ignores_tool_mypy_config_entries(tmp_path: Path) -> None:
    """Guard should not flag TOML mypy configuration lines."""
    repo_root = tmp_path
    file_path = _write(
        repo_root / "documents/engineering/dependency_management.md",
        'mypy = "^1.7.0"\n[tool.mypy]\n',
    )

    violations = find_policy_violations(repo_root, target_files=(file_path,))

    assert violations == ()


def test_guard_ignores_regular_mypy_prose(tmp_path: Path) -> None:
    """Guard should not flag non-command prose mentioning mypy."""
    repo_root = tmp_path
    file_path = _write(
        repo_root / "CLAUDE.md",
        "The project uses ultra-strict mypy configuration.\n",
    )

    violations = find_policy_violations(repo_root, target_files=(file_path,))

    assert violations == ()
