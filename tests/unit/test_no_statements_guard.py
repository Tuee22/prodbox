"""Unit tests for no-statements policy guard."""

from __future__ import annotations

from pathlib import Path

import pytest

from prodbox.lib.lint.no_statements_guard import (
    ENFORCE_MODE,
    INFORMATIONAL_MODE,
    NO_STATEMENTS_MODE_ENV,
    find_statement_violations,
    main,
)


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_statement_guard_allows_boundary_file_with_if(tmp_path: Path) -> None:
    boundary_file = _write(
        tmp_path / "src" / "prodbox" / "cli" / "interpreter.py",
        "def f(x: int) -> int:\n" "    if x > 0:\n" "        return x\n" "    return -x\n",
    )

    violations = find_statement_violations(tmp_path, target_files=(boundary_file,))

    assert violations == ()


def test_statement_guard_flags_if_statement(tmp_path: Path) -> None:
    file_path = _write(
        tmp_path / "src" / "prodbox" / "cli" / "sample.py",
        "def f(x: int) -> int:\n" "    if x > 0:\n" "        return x\n" "    return -x\n",
    )

    violations = find_statement_violations(tmp_path, target_files=(file_path,))

    assert len(violations) == 1
    assert violations[0].relative_path == Path("src/prodbox/cli/sample.py")
    assert violations[0].line_number == 2
    assert "if statement is forbidden" in violations[0].reason


def test_statement_guard_flags_for_loop(tmp_path: Path) -> None:
    file_path = _write(
        tmp_path / "src" / "prodbox" / "cli" / "sample.py",
        "def f(items: tuple[int, ...]) -> int:\n"
        "    total = 0\n"
        "    for item in items:\n"
        "        total += item\n"
        "    return total\n",
    )

    violations = find_statement_violations(tmp_path, target_files=(file_path,))

    assert len(violations) == 1
    assert violations[0].relative_path == Path("src/prodbox/cli/sample.py")
    assert violations[0].line_number == 3
    assert "loop statement is forbidden" in violations[0].reason


def test_main_informational_mode_is_non_blocking(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write(
        tmp_path / "src" / "prodbox" / "cli" / "sample.py",
        "def f(x: int) -> int:\n" "    if x > 0:\n" "        return x\n" "    return -x\n",
    )
    monkeypatch.setattr("prodbox.lib.lint.no_statements_guard.repo_root", lambda: tmp_path)
    monkeypatch.setenv(NO_STATEMENTS_MODE_ENV, INFORMATIONAL_MODE)

    exit_code = main()
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "no_statements_guard: INFO" in captured.out
    assert captured.err == ""


def test_main_enforce_mode_fails_on_violations(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write(
        tmp_path / "src" / "prodbox" / "cli" / "sample.py",
        "def f(x: int) -> int:\n" "    if x > 0:\n" "        return x\n" "    return -x\n",
    )
    monkeypatch.setattr("prodbox.lib.lint.no_statements_guard.repo_root", lambda: tmp_path)
    monkeypatch.setenv(NO_STATEMENTS_MODE_ENV, ENFORCE_MODE)

    exit_code = main()
    captured = capsys.readouterr()

    assert exit_code == 1
    assert "no_statements_guard: FAIL" in captured.err
    assert "forbidden statement control flow" in captured.err
