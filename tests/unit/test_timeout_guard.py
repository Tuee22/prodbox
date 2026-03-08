"""Unit tests for timeout policy guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.timeout_guard import find_timeout_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_timeout_guard_allows_positive_timeout_constant(tmp_path: Path) -> None:
    """Guard should allow named positive timeout constants."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "runner.py",
        "\n".join(
            [
                "from prodbox.cli.effects import RunSubprocess",
                "TIMEOUT_SECONDS = 120.0",
                "effect = RunSubprocess(",
                "    effect_id='x',",
                "    description='x',",
                "    command=['echo', 'ok'],",
                "    timeout=TIMEOUT_SECONDS,",
                ")",
                "",
            ]
        ),
    )
    violations = find_timeout_violations(repo_root, target_files=(file_path,))
    assert violations == ()


def test_timeout_guard_flags_none_timeout(tmp_path: Path) -> None:
    """Guard should reject None timeout values."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "runner.py",
        "\n".join(
            [
                "from prodbox.cli.effects import RunSubprocess",
                "TIMEOUT_SECONDS = None",
                "effect = RunSubprocess(",
                "    effect_id='x',",
                "    description='x',",
                "    command=['echo', 'ok'],",
                "    timeout=TIMEOUT_SECONDS,",
                ")",
                "",
            ]
        ),
    )
    violations = find_timeout_violations(repo_root, target_files=(file_path,))
    assert len(violations) == 1
