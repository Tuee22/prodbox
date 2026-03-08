"""Unit tests for no-shell policy guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.no_shell_guard import find_shell_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_no_shell_guard_allows_exec_mode_command_lists(tmp_path: Path) -> None:
    """Guard should allow exec-mode subprocess usage."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "ok.py",
        "\n".join(
            [
                "from subprocess import run",
                "",
                "def good() -> None:",
                "    run(['echo', 'ok'])",
                "",
            ]
        ),
    )
    violations = find_shell_violations(repo_root, target_files=(file_path,))
    assert violations == ()


def test_no_shell_guard_flags_shell_true(tmp_path: Path) -> None:
    """Guard should reject shell=True usage."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "bad.py",
        "\n".join(
            [
                "from subprocess import run",
                "",
                "def bad() -> None:",
                "    run('echo bad', shell=True)",
                "",
            ]
        ),
    )
    violations = find_shell_violations(repo_root, target_files=(file_path,))
    assert len(violations) == 1
