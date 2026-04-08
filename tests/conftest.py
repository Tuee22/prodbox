"""Pytest fixtures for prodbox tests."""

from __future__ import annotations

import asyncio
import gc
import os
from collections.abc import Generator
from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

import prodbox.settings as settings_module
from prodbox.settings import Settings, clear_settings_cache


def _close_current_policy_loop(*, context: str) -> None:
    """Close the current policy event loop when a test leaves one behind."""
    policy = asyncio.get_event_loop_policy()
    local = getattr(policy, "_local", None)
    loop = getattr(local, "_loop", None) if local is not None else None
    if loop is None:
        return
    if loop.is_running():
        raise AssertionError(f"{context} leaked a running event loop")
    if not loop.is_closed():
        loop.close()
    asyncio.set_event_loop(None)
    gc.collect()


def _close_orphan_event_loops(*, context: str) -> None:
    """Close any orphaned asyncio event loops before pytest session teardown."""
    loops = tuple(obj for obj in gc.get_objects() if isinstance(obj, asyncio.AbstractEventLoop))
    for loop in loops:
        if loop.is_running():
            raise AssertionError(f"{context} leaked a running event loop")
        if not loop.is_closed():
            loop.close()
    asyncio.set_event_loop(None)
    gc.collect()


@pytest.fixture(autouse=True)
def clear_settings() -> Generator[None, None, None]:
    """Clear settings cache before and after each test."""
    clear_settings_cache()
    yield
    clear_settings_cache()


@pytest.fixture(autouse=True)
def close_sync_test_event_loop(request: pytest.FixtureRequest) -> Generator[None, None, None]:
    """Close any current event loop left behind by a synchronous test."""
    yield
    if request.node.get_closest_marker("asyncio") is not None:
        return
    _close_current_policy_loop(context=f"sync test {request.node.nodeid}")


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """Close orphaned event loops before pytest final unconfigure cleanup."""
    _ = session
    _ = exitstatus
    _close_orphan_event_loops(context="pytest session")


@pytest.fixture
def mock_env(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> Generator[dict[str, str], None, None]:
    """Provide a complete mock environment for settings.

    This fixture patches os.environ with non-auth settings and writes
    `.env` AWS credentials into an isolated temporary working directory.
    """
    monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".env").write_text(
        "\n".join(
            [
                "AWS_ACCESS_KEY_ID=test-access-key",
                "AWS_SECRET_ACCESS_KEY=test-secret-key",
                "AWS_SESSION_TOKEN=test-session-token",
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = {
        "AWS_REGION": "us-east-1",
        "ROUTE53_ZONE_ID": "Z1234567890ABC",
        "ACME_EMAIL": "test@example.com",
        "DEMO_FQDN": "test.example.com",
        "DEMO_TTL": "60",
        "ACME_SERVER": "https://acme-staging-v02.api.letsencrypt.org/directory",
    }
    with patch.dict(os.environ, env, clear=True):
        yield env


@pytest.fixture
def settings(mock_env: dict[str, str]) -> Settings:  # noqa: ARG001
    """Get a Settings instance with mock environment."""
    return Settings()


@pytest.fixture
def cli_runner() -> CliRunner:
    """Click CLI test runner."""
    return CliRunner()


@pytest.fixture
def mock_subprocess() -> Generator[None, None, None]:
    """Mock the subprocess runner for CLI tests."""
    with patch("prodbox.lib.subprocess.run_command") as mock:
        yield mock
