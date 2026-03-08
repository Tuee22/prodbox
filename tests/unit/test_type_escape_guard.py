"""Unit tests for type-escape policy guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.type_escape_guard import find_type_escape_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_type_escape_guard_allows_typed_code(tmp_path: Path) -> None:
    """Guard should allow regular typed code without escapes."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "ok.py",
        "\n".join(
            [
                "def parse(value: str) -> int:",
                "    return int(value)",
                "",
            ]
        ),
    )
    violations = find_type_escape_violations(repo_root, target_files=(file_path,))
    assert violations == ()


def test_type_escape_guard_flags_any_import(tmp_path: Path) -> None:
    """Guard should reject Any/cast/type-ignore escapes."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "bad.py",
        "\n".join(
            [
                "from typing import Any, cast",
                "",
                "value: Any = 1  # type: ignore[misc]",
                "x = cast(int, value)",
                "",
            ]
        ),
    )
    violations = find_type_escape_violations(repo_root, target_files=(file_path,))
    assert len(violations) >= 1
