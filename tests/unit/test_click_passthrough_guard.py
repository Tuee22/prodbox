"""Unit tests for the Click passthrough guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.click_passthrough_guard import find_click_passthrough_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_click_passthrough_guard_accepts_explicit_click_surface(tmp_path: Path) -> None:
    """Explicit Click commands with named options/args should pass."""
    repo_root = tmp_path / "repo"
    cli_file = _write(
        repo_root / "src" / "prodbox" / "cli" / "sample.py",
        """
import click

@click.group()
def root() -> None:
    pass

@root.command()
@click.option("--flag", is_flag=True)
def child(flag: bool) -> None:
    pass
""".strip(),
    )
    violations = find_click_passthrough_violations(repo_root, target_files=(cli_file,))
    assert violations == ()


def test_click_passthrough_guard_flags_context_settings_passthrough(tmp_path: Path) -> None:
    """allow_extra_args/ignore_unknown_options should be rejected."""
    repo_root = tmp_path / "repo"
    cli_file = _write(
        repo_root / "src" / "prodbox" / "cli" / "sample.py",
        """
import click

@click.command(context_settings={"allow_extra_args": True, "ignore_unknown_options": True})
def sample() -> None:
    pass
""".strip(),
    )
    violations = find_click_passthrough_violations(repo_root, target_files=(cli_file,))
    assert len(violations) == 1
    assert "allow_extra_args" in violations[0].reason


def test_click_passthrough_guard_flags_variadic_click_arguments(tmp_path: Path) -> None:
    """nargs=-1 Click arguments should be rejected."""
    repo_root = tmp_path / "repo"
    cli_file = _write(
        repo_root / "src" / "prodbox" / "cli" / "sample.py",
        """
import click

@click.command()
@click.argument("args", nargs=-1)
def sample(args: tuple[str, ...]) -> None:
    pass
""".strip(),
    )
    violations = find_click_passthrough_violations(repo_root, target_files=(cli_file,))
    assert len(violations) == 1
    assert "nargs=-1" in violations[0].reason


def test_click_passthrough_guard_flags_unprocessed_arguments(tmp_path: Path) -> None:
    """click.UNPROCESSED should be rejected."""
    repo_root = tmp_path / "repo"
    cli_file = _write(
        repo_root / "src" / "prodbox" / "cli" / "sample.py",
        """
import click

@click.command()
@click.argument("args", type=click.UNPROCESSED)
def sample(args: str) -> None:
    pass
""".strip(),
    )
    violations = find_click_passthrough_violations(repo_root, target_files=(cli_file,))
    assert len(violations) == 1
    assert "UNPROCESSED" in violations[0].reason
