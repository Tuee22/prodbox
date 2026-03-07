"""Unit tests for the no-test-skip policy guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.no_test_skip_guard import find_skip_policy_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_skip_guard_allows_non_skip_pytest_markers(tmp_path: Path) -> None:
    """Guard should allow normal pytest markers (for example integration)."""
    repo_root = tmp_path / "repo"
    test_file = _write(
        repo_root / "tests" / "integration" / "test_ok.py",
        "\n".join(
            [
                "import pytest",
                "",
                "@pytest.mark.integration",
                "def test_ok() -> None:",
                "    assert True",
                "",
            ]
        ),
    )

    violations = find_skip_policy_violations(repo_root, target_files=(test_file,))
    assert violations == ()


def test_skip_guard_flags_pytest_skip_call(tmp_path: Path) -> None:
    """Guard should reject pytest.skip runtime calls."""
    repo_root = tmp_path / "repo"
    test_file = _write(
        repo_root / "tests" / "integration" / "test_skip_call.py",
        "\n".join(
            [
                "import pytest",
                "",
                "def test_skip() -> None:",
                "    pytest.skip('no environment')",
                "",
            ]
        ),
    )

    violations = find_skip_policy_violations(repo_root, target_files=(test_file,))
    assert len(violations) == 1
    assert "pytest.skip" in violations[0].reason


def test_skip_guard_flags_skip_decorator(tmp_path: Path) -> None:
    """Guard should reject skip decorators."""
    repo_root = tmp_path / "repo"
    test_file = _write(
        repo_root / "tests" / "integration" / "test_skip_decorator.py",
        "\n".join(
            [
                "import pytest",
                "",
                "@pytest.mark.skip(reason='not ready')",
                "def test_skip_decorated() -> None:",
                "    assert True",
                "",
            ]
        ),
    )

    violations = find_skip_policy_violations(repo_root, target_files=(test_file,))
    assert len(violations) == 1
    assert "decorator" in violations[0].reason


def test_skip_guard_flags_imported_skip_alias(tmp_path: Path) -> None:
    """Guard should reject imported skip aliases from pytest."""
    repo_root = tmp_path / "repo"
    test_file = _write(
        repo_root / "tests" / "integration" / "test_skip_alias.py",
        "\n".join(
            [
                "from pytest import skip as skip_test",
                "",
                "def test_skip_alias() -> None:",
                "    skip_test('not configured')",
                "",
            ]
        ),
    )

    violations = find_skip_policy_violations(repo_root, target_files=(test_file,))
    assert len(violations) == 1
    assert "alias" in violations[0].reason
