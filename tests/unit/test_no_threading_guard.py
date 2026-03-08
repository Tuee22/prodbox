"""Unit tests for no-threading policy guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.no_threading_guard import find_threading_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_no_threading_guard_allows_asyncio(tmp_path: Path) -> None:
    """Guard should allow asyncio usage."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "ok.py",
        "\n".join(
            [
                "import asyncio",
                "",
                "async def run() -> None:",
                "    await asyncio.sleep(0)",
                "",
            ]
        ),
    )
    violations = find_threading_violations(repo_root, target_files=(file_path,))
    assert violations == ()


def test_no_threading_guard_flags_threading_import(tmp_path: Path) -> None:
    """Guard should reject threading usage."""
    repo_root = tmp_path / "repo"
    file_path = _write(
        repo_root / "src" / "prodbox" / "cli" / "bad.py",
        "\n".join(
            [
                "import threading",
                "",
                "def bad() -> None:",
                "    lock = threading.Lock()",
                "    _ = lock",
                "",
            ]
        ),
    )
    violations = find_threading_violations(repo_root, target_files=(file_path,))
    assert len(violations) >= 1
