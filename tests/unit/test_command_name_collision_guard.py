"""Unit tests for command-name collision guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.command_name_collision_guard import find_command_name_collisions


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_collision_guard_allows_non_test_prefixed_command(tmp_path: Path) -> None:
    """Guard should allow normal Click command names."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "ok.py",
        "\n".join(
            [
                "import click",
                "",
                "@click.command()",
                "def run_health() -> None:",
                "    return None",
                "",
            ]
        ),
    )
    violations = find_command_name_collisions(repo_root, target_files=(file_path,))
    assert violations == ()


def test_collision_guard_flags_test_prefixed_click_command(tmp_path: Path) -> None:
    """Guard should reject test_* click command function names."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "bad.py",
        "\n".join(
            [
                "import click",
                "",
                "@click.command()",
                "def test_run() -> None:",
                "    return None",
                "",
            ]
        ),
    )
    violations = find_command_name_collisions(repo_root, target_files=(file_path,))
    assert len(violations) == 1
