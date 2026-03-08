"""Unit tests for purity guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.purity_guard import find_purity_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def _seed_pure_files(repo_root: Path) -> None:
    _write(
        repo_root / "src" / "prodbox" / "cli" / "command_adt.py",
        "def build() -> int:\n    return 1\n",
    )
    _write(
        repo_root / "src" / "prodbox" / "cli" / "dag_builders.py",
        "def build_dag() -> int:\n    return 1\n",
    )
    _write(
        repo_root / "src" / "prodbox" / "cli" / "effect_dag.py",
        "def expand() -> int:\n    return 1\n",
    )
    _write(
        repo_root / "src" / "prodbox" / "cli" / "command_executor.py",
        "def ok() -> None:\n    create_interpreter()\n",
    )
    _write(
        repo_root / "src" / "prodbox" / "cli" / "interpreter.py",
        "class EffectInterpreter:\n    pass\n",
    )


def test_purity_guard_allows_interpreter_at_boundary(tmp_path: Path) -> None:
    """Guard should allow interpreter creation in boundary files."""
    repo_root = tmp_path / "repo"
    _seed_pure_files(repo_root)
    violations = find_purity_violations(repo_root)
    assert violations == ()


def test_purity_guard_flags_interpreter_outside_boundary(tmp_path: Path) -> None:
    """Guard should reject interpreter creation outside allowed files."""
    repo_root = tmp_path / "repo"
    _seed_pure_files(repo_root)
    _write(
        repo_root / "src" / "prodbox" / "cli" / "dns.py",
        "def bad() -> None:\n    create_interpreter()\n",
    )
    violations = find_purity_violations(repo_root)
    assert len(violations) == 1
