"""Pytest fixtures for prodbox tests."""

from __future__ import annotations

import asyncio
import gc
import os
from collections.abc import Generator
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from prodbox.settings import Settings, clear_settings_cache


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

    policy = asyncio.get_event_loop_policy()
    local = getattr(policy, "_local", None)
    loop = getattr(local, "_loop", None) if local is not None else None
    if loop is None:
        return
    if loop.is_running():
        raise AssertionError(f"sync test leaked a running event loop: {request.node.nodeid}")
    if not loop.is_closed():
        loop.close()
    asyncio.set_event_loop(None)
    gc.collect()


@pytest.fixture
def mock_env() -> Generator[dict[str, str], None, None]:
    """Provide a complete mock environment for settings.

    This fixture patches os.environ with test values for all
    required settings, allowing tests to run without real credentials.
    """
    env = {
        "AWS_ACCESS_KEY_ID": "test-access-key-id",
        "AWS_SECRET_ACCESS_KEY": "test-secret-access-key",
        "AWS_REGION": "us-east-1",
        "ROUTE53_ZONE_ID": "Z1234567890ABC",
        "ACME_EMAIL": "test@example.com",
        "DEMO_FQDN": "test.example.com",
        "DEMO_TTL": "60",
        "METALLB_POOL": "10.0.0.100-10.0.0.110",
        "INGRESS_LB_IP": "10.0.0.100",
        "KUBECONFIG": "/tmp/test-kubeconfig",
        "ACME_SERVER": "https://acme-staging-v02.api.letsencrypt.org/directory",
        "PULUMI_STACK": "test",
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
