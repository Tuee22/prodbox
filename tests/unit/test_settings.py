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

        assert settings.aws_region == "us-east-1"
        assert settings.route53_zone_id == "Z1234567890ABC"
        assert settings.acme_email == "test@example.com"
        assert settings.demo_fqdn == "test.example.com"
        assert settings.demo_ttl == 60
        assert settings.metallb_pool == "10.0.0.100-10.0.0.110"
        assert settings.ingress_lb_ip == "10.0.0.100"

    def test_settings_requires_route53_zone_id(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should fail without Route 53 zone ID."""
        monkeypatch.chdir(tmp_path)
        env = {
            "ACME_EMAIL": "test@example.com",
        }
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            error_fields = {e["loc"][0] for e in errors}
            assert "route53_zone_id" in error_fields

    def test_settings_requires_acme_email(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should fail without ACME email."""
        monkeypatch.chdir(tmp_path)
        env = {
            "ROUTE53_ZONE_ID": "Z123",
        }
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            error_fields = {e["loc"][0] for e in errors}
            assert "acme_email" in error_fields

    def test_settings_rejects_aws_auth_env_vars(self) -> None:
        """Settings should reject env-var-based AWS auth."""
        env = {
            "ROUTE53_ZONE_ID": "Z123",
            "ACME_EMAIL": "test@example.com",
            "AWS_ACCESS_KEY_ID": "forbidden",
        }
        with (
            patch.dict(os.environ, env, clear=True),
            pytest.raises(ValidationError, match="AWS auth env vars are forbidden"),
        ):
            Settings()

    def test_settings_rejects_repo_local_dotenv_auth_vars(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should reject repo-local dotenv files that define AWS auth vars."""
        (tmp_path / ".env").write_text(
            "\n".join(
                [
                    "ROUTE53_ZONE_ID=Z123",
                    "ACME_EMAIL=test@example.com",
                    "AWS_ACCESS_KEY_ID=forbidden",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        monkeypatch.chdir(tmp_path)
        with (
            patch.dict(os.environ, {}, clear=True),
            pytest.raises(ValidationError, match="must not define AWS auth env vars"),
        ):
            Settings()

    def test_settings_default_values(
        self,
        mock_env: dict[str, str],  # noqa: ARG002
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should use default values when not specified."""
        monkeypatch.chdir(tmp_path)
        env = {
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
        env = {**mock_env, "DEMO_TTL": "10"}
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            assert any("demo_ttl" in str(e["loc"]) for e in errors)

        env = {**mock_env, "DEMO_TTL": "100000"}
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(ValidationError) as exc_info:
                Settings()

            errors = exc_info.value.errors()
            assert any("demo_ttl" in str(e["loc"]) for e in errors)


class TestDisplayDict:
    """Tests for Settings.display_dict() method."""

    def test_returns_non_secret_values(self, settings: Settings) -> None:
        """display_dict should return the supported configuration surface."""
        display = settings.display_dict()

        assert display["aws_region"] == "us-east-1"
        assert display["route53_zone_id"] == "Z1234567890ABC"
        assert display["demo_fqdn"] == "test.example.com"
        assert display["acme_email"] == "****.com"

    def test_show_secrets_reveals_sensitive_values(self, settings: Settings) -> None:
        """display_dict(show_secrets=True) should unmask sensitive settings."""
        assert settings.display_dict(show_secrets=True)["acme_email"] == "test@example.com"


class TestRenderedSettings:
    """Tests for deterministic rendered settings output."""

    def test_render_display_lists_supported_settings(self, settings: Settings) -> None:
        """render_display should omit forbidden AWS auth env vars."""
        rendered = settings.render_display()

        assert "AWS_REGION=us-east-1" in rendered
        assert "ROUTE53_ZONE_ID=Z1234567890ABC" in rendered
        assert "ACME_EMAIL=****.com" in rendered
        assert "AWS_ACCESS_KEY_ID=" not in rendered
        assert "AWS_SECRET_ACCESS_KEY=" not in rendered

    def test_render_display_show_secrets_reveals_sensitive_values(
        self,
        settings: Settings,
    ) -> None:
        """render_display(show_secrets=True) should unmask sensitive settings."""
        rendered = settings.render_display(show_secrets=True)

        assert "ACME_EMAIL=test@example.com" in rendered
        assert "ACME_EMAIL=****.com" not in rendered

    def test_render_template_contains_required_and_optional_settings(self) -> None:
        """render_template should list required and optional variables deterministically."""
        template = Settings.render_template()

        assert "# prodbox environment template" in template
        assert "ROUTE53_ZONE_ID=" in template
        assert "AWS_REGION=us-east-1" in template
        assert "BOOTSTRAP_PUBLIC_IP_OVERRIDE=" in template
        assert "AWS_ACCESS_KEY_ID=" not in template


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

        assert settings1 is not settings2
        assert settings1.demo_fqdn == settings2.demo_fqdn
