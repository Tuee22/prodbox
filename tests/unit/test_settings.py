"""Unit tests for prodbox settings."""

from __future__ import annotations

import os
from pathlib import Path
from unittest.mock import patch

import pytest
from pydantic import ValidationError

from prodbox.settings import Settings, clear_settings_cache, get_settings


class TestSettings:
    """Tests for Settings class."""

    def test_settings_loads_from_env(
        self,
        mock_env: dict[str, str],  # noqa: ARG002
    ) -> None:
        """Settings should load from environment variables."""
        settings = Settings()

        assert settings.aws_access_key_id == "test-access-key-id"
        assert settings.aws_secret_access_key == "test-secret-access-key"
        assert settings.aws_region == "us-east-1"
        assert settings.route53_zone_id == "Z1234567890ABC"
        assert settings.acme_email == "test@example.com"
        assert settings.demo_fqdn == "test.example.com"
        assert settings.demo_ttl == 60
        assert settings.metallb_pool == "10.0.0.100-10.0.0.110"
        assert settings.ingress_lb_ip == "10.0.0.100"

    def test_settings_requires_aws_credentials(self) -> None:
        """Settings should fail without required AWS credentials."""
        with patch.dict(os.environ, {}, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            error_fields = {e["loc"][0] for e in errors}
            assert "aws_access_key_id" in error_fields
            assert "aws_secret_access_key" in error_fields

    def test_settings_requires_route53_zone_id(self) -> None:
        """Settings should fail without Route 53 zone ID."""
        env = {
            "AWS_ACCESS_KEY_ID": "test",
            "AWS_SECRET_ACCESS_KEY": "test",
            "ACME_EMAIL": "test@example.com",
        }
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            error_fields = {e["loc"][0] for e in errors}
            assert "route53_zone_id" in error_fields

    def test_settings_requires_acme_email(self) -> None:
        """Settings should fail without ACME email."""
        env = {
            "AWS_ACCESS_KEY_ID": "test",
            "AWS_SECRET_ACCESS_KEY": "test",
            "ROUTE53_ZONE_ID": "Z123",
        }
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            error_fields = {e["loc"][0] for e in errors}
            assert "acme_email" in error_fields

    def test_settings_default_values(
        self,
        mock_env: dict[str, str],  # noqa: ARG002
    ) -> None:
        """Settings should use default values when not specified."""
        # Remove optional env vars to test defaults
        env = {
            "AWS_ACCESS_KEY_ID": "test",
            "AWS_SECRET_ACCESS_KEY": "test",
            "ROUTE53_ZONE_ID": "Z123",
            "ACME_EMAIL": "test@example.com",
        }
        with patch.dict(os.environ, env, clear=True):
            settings = Settings()

            assert settings.aws_region == "us-east-1"
            assert settings.demo_fqdn == "demo.example.com"
            assert settings.demo_ttl == 60
            assert settings.metallb_pool == "192.168.1.240-192.168.1.250"
            assert settings.ingress_lb_ip == "192.168.1.240"
            assert settings.pulumi_stack == "home"

    def test_settings_kubeconfig_expansion(self, mock_env: dict[str, str]) -> None:
        """Settings should expand ~ in kubeconfig path."""
        env = {**mock_env, "KUBECONFIG": "~/.kube/config"}
        with patch.dict(os.environ, env, clear=True):
            settings = Settings()

            assert settings.kubeconfig == Path.home() / ".kube" / "config"
            assert "~" not in str(settings.kubeconfig)

    def test_settings_ttl_validation(self, mock_env: dict[str, str]) -> None:
        """Settings should validate TTL range."""
        # TTL too low
        env = {**mock_env, "DEMO_TTL": "10"}
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            assert any("demo_ttl" in str(e["loc"]) for e in errors)

        # TTL too high
        env = {**mock_env, "DEMO_TTL": "100000"}
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            assert any("demo_ttl" in str(e["loc"]) for e in errors)


class TestDisplayDict:
    """Tests for Settings.display_dict() method."""

    def test_masks_sensitive_values(self, settings: Settings) -> None:
        """display_dict should mask sensitive values."""
        display = settings.display_dict()

        # Secret should be masked
        assert "****" in display["aws_secret_access_key"]
        assert "test-secret-access-key" not in display["aws_secret_access_key"]

        # Non-sensitive values should not be masked
        assert display["aws_access_key_id"] == "test-access-key-id"
        assert display["demo_fqdn"] == "test.example.com"

    def test_shows_last_four_chars_of_secret(self, settings: Settings) -> None:
        """display_dict should show last 4 chars of masked secrets."""
        display = settings.display_dict()

        # Should end with last 4 chars of secret
        assert display["aws_secret_access_key"].endswith("-key")

    def test_show_secrets_option_returns_unmasked_values(self, settings: Settings) -> None:
        """display_dict(show_secrets=True) should return unmasked secret values."""
        display = settings.display_dict(show_secrets=True)

        assert display["aws_secret_access_key"] == "test-secret-access-key"


class TestRenderedSettings:
    """Tests for deterministic rendered settings output."""

    def test_render_display_masks_secrets_by_default(self, settings: Settings) -> None:
        """render_display should mask secret values by default."""
        rendered = settings.render_display()

        assert "AWS_SECRET_ACCESS_KEY=****-key" in rendered
        assert "AWS_SECRET_ACCESS_KEY=test-secret-access-key" not in rendered
        assert "AWS_ACCESS_KEY_ID=test-access-key-id" in rendered

    def test_render_display_show_secrets_exposes_secret(self, settings: Settings) -> None:
        """render_display(show_secrets=True) should expose full secret values."""
        rendered = settings.render_display(show_secrets=True)

        assert "AWS_SECRET_ACCESS_KEY=test-secret-access-key" in rendered

    def test_render_template_contains_required_and_optional_settings(self) -> None:
        """render_template should list required and optional variables deterministically."""
        template = Settings.render_template()

        assert "# prodbox environment template" in template
        assert "AWS_ACCESS_KEY_ID=" in template
        assert "AWS_REGION=us-east-1" in template
        assert "BOOTSTRAP_PUBLIC_IP_OVERRIDE=" in template


class TestGetSettings:
    """Tests for get_settings() function."""

    def test_caches_settings(
        self,
        mock_env: dict[str, str],  # noqa: ARG002
    ) -> None:
        """get_settings should cache the settings instance."""
        settings1 = get_settings()
        settings2 = get_settings()

        assert settings1 is settings2

    def test_clear_cache_reloads_settings(
        self,
        mock_env: dict[str, str],  # noqa: ARG002
    ) -> None:
        """clear_settings_cache should force reload."""
        settings1 = get_settings()
        clear_settings_cache()
        settings2 = get_settings()

        # New instance after cache clear
        assert settings1 is not settings2
        # But same values
        assert settings1.demo_fqdn == settings2.demo_fqdn
