"""Unit tests for infra DNS bootstrap behavior."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from prodbox.infra.dns import get_public_ip


def test_get_public_ip_returns_override_when_provided() -> None:
    """Explicit bootstrap overrides should take precedence over network lookup."""
    assert get_public_ip(bootstrap_override="203.0.113.10") == "203.0.113.10"


def test_get_public_ip_fetches_live_value_when_no_override() -> None:
    """Live public IP lookup should return the fetched address."""
    mock_response = MagicMock()
    mock_response.text = "198.51.100.7"
    mock_response.raise_for_status = MagicMock()

    with patch("httpx.get", return_value=mock_response):
        assert get_public_ip() == "198.51.100.7"


def test_get_public_ip_fails_fast_without_override_on_network_error() -> None:
    """Bootstrap IP lookup should fail fast when live detection fails."""
    with (
        patch("httpx.get", side_effect=RuntimeError("network down")),
        pytest.raises(RuntimeError, match="BOOTSTRAP_PUBLIC_IP_OVERRIDE"),
    ):
        get_public_ip()
