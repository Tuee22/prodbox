"""Unit tests for context module."""

from __future__ import annotations

import os
from unittest.mock import patch

from prodbox.cli.context import SettingsContext, pass_settings
from prodbox.settings import Settings


class TestSettingsContext:
    """Tests for SettingsContext class."""

    def test_settings_context_holds_settings(self, mock_env: dict[str, str]) -> None:
        """SettingsContext should hold settings instance."""
        with patch.dict(os.environ, mock_env, clear=True):
            settings = Settings()
            ctx = SettingsContext(settings)

            assert ctx.settings is settings

    def test_settings_context_exposes_settings_attrs(self, mock_env: dict[str, str]) -> None:
        """SettingsContext.settings should have expected attributes."""
        with patch.dict(os.environ, mock_env, clear=True):
            settings = Settings()
            ctx = SettingsContext(settings)

            assert ctx.settings.demo_fqdn == "test.example.com"
            assert ctx.settings.aws_region == "us-east-1"


class TestPassSettings:
    """Tests for pass_settings decorator."""

    def test_pass_settings_is_decorator(self) -> None:
        """pass_settings should be a Click decorator."""
        # Just verify it's callable
        assert callable(pass_settings)
