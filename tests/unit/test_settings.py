"""Unit tests for prodbox settings."""

from __future__ import annotations

import ipaddress
import os
from pathlib import Path
from unittest.mock import patch

import pytest
from pydantic import ValidationError

import prodbox.settings as settings_module
from prodbox.settings import (
    LanAddressing,
    Settings,
    _build_ifreq,
    _default_route_interface_name,
    _discover_lan_addressing_or_none,
    _select_metallb_range,
    clear_settings_cache,
    discover_lan_addressing,
    get_settings,
)


def _write_aws_auth_dotenv(path: Path) -> None:
    """Write minimal `.env` AWS auth required by settings validation."""
    (path / ".env").write_text(
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


def _patch_repository_root(monkeypatch: pytest.MonkeyPatch, path: Path) -> None:
    """Point settings resolution at an isolated repository root for one test."""
    monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", path)


def _lan_addressing(
    *,
    interface_name: str = "enp1s0",
    interface_ipv4: str = "192.168.1.10",
    network_cidr: str = "192.168.1.0/24",
    metallb_pool: str = "192.168.1.240-192.168.1.250",
    ingress_lb_ip: str = "192.168.1.240",
) -> LanAddressing:
    """Return deterministic LAN discovery data for tests."""
    return LanAddressing(
        interface_name=interface_name,
        interface_ipv4=interface_ipv4,
        network_cidr=network_cidr,
        metallb_pool=metallb_pool,
        ingress_lb_ip=ingress_lb_ip,
    )


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

    def test_settings_requires_route53_zone_id(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should fail without Route 53 zone ID."""
        _patch_repository_root(monkeypatch, tmp_path)
        _write_aws_auth_dotenv(tmp_path)
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
        _patch_repository_root(monkeypatch, tmp_path)
        _write_aws_auth_dotenv(tmp_path)
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

    def test_settings_rejects_aws_auth_env_vars(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should reject ambient AWS auth env vars outside `.env`."""
        _patch_repository_root(monkeypatch, tmp_path)
        _write_aws_auth_dotenv(tmp_path)
        monkeypatch.chdir(tmp_path)
        env = {
            "ROUTE53_ZONE_ID": "Z123",
            "ACME_EMAIL": "test@example.com",
            "AWS_ACCESS_KEY_ID": "forbidden",
        }
        with (
            patch.dict(os.environ, env, clear=True),
            pytest.raises(ValidationError, match="Ambient AWS auth env vars are forbidden"),
        ):
            Settings()

    def test_settings_requires_repo_local_dotenv_auth_vars(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should fail when repo-local `.env` omits AWS auth vars."""
        _patch_repository_root(monkeypatch, tmp_path)
        (tmp_path / ".env").write_text(
            "\n".join(
                [
                    "ROUTE53_ZONE_ID=Z123",
                    "ACME_EMAIL=test@example.com",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        monkeypatch.chdir(tmp_path)
        with (
            patch.dict(os.environ, {}, clear=True),
            pytest.raises(ValidationError, match="must define AWS auth for prodbox"),
        ):
            Settings()

    def test_settings_default_values(
        self,
        mock_env: dict[str, str],  # noqa: ARG002
    ) -> None:
        """Settings should use default values when not specified."""
        env = {
            "ROUTE53_ZONE_ID": "Z123",
            "ACME_EMAIL": "test@example.com",
        }
        with (
            patch.dict(os.environ, env, clear=True),
            patch(
                "prodbox.settings._discover_lan_addressing_or_none",
                return_value=_lan_addressing(),
            ),
        ):
            settings = Settings()

            assert settings.aws_region == "us-east-1"
            assert settings.demo_fqdn == "demo.example.com"
            assert settings.demo_ttl == 60
            assert settings.active_lan_interface == "enp1s0"
            assert settings.active_lan_ipv4 == "192.168.1.10"
            assert settings.active_lan_network_cidr == "192.168.1.0/24"

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

    def test_settings_auto_derives_local_edge_defaults(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should derive canonical LAN-backed defaults when blank."""
        _patch_repository_root(monkeypatch, tmp_path)
        _write_aws_auth_dotenv(tmp_path)
        monkeypatch.chdir(tmp_path)

        env = {
            "ROUTE53_ZONE_ID": "Z123",
            "ACME_EMAIL": "test@example.com",
        }
        with (
            patch.dict(os.environ, env, clear=True),
            patch(
                "prodbox.settings._discover_lan_addressing_or_none",
                return_value=_lan_addressing(
                    interface_name="eno1",
                    interface_ipv4="192.168.50.20",
                    network_cidr="192.168.50.0/24",
                    metallb_pool="192.168.50.240-192.168.50.250",
                    ingress_lb_ip="192.168.50.240",
                ),
            ),
        ):
            settings = Settings()

        assert settings.active_lan_interface == "eno1"
        assert settings.active_lan_ipv4 == "192.168.50.20"
        assert settings.active_lan_network_cidr == "192.168.50.0/24"

    def test_settings_load_repo_dotenv_from_nested_subdirectory(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should load only the fixed repository-root `.env` from nested cwd."""
        repo_root = tmp_path / "repo"
        nested_dir = repo_root / "src" / "prodbox" / "infra"
        nested_dir.mkdir(parents=True)
        _patch_repository_root(monkeypatch, repo_root)
        (repo_root / ".env").write_text(
            "\n".join(
                [
                    "AWS_ACCESS_KEY_ID=test-access-key",
                    "AWS_SECRET_ACCESS_KEY=test-secret-key",
                    "AWS_SESSION_TOKEN=test-session-token",
                    "ROUTE53_ZONE_ID=Z1234567890ABC",
                    "ACME_EMAIL=test@example.com",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        monkeypatch.chdir(nested_dir)

        with patch.dict(os.environ, {}, clear=True):
            settings = Settings()

        assert settings.route53_zone_id == "Z1234567890ABC"
        assert settings.acme_email == "test@example.com"

    def test_settings_ignores_nested_dotenv_when_repo_root_dotenv_is_missing(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Settings should not fall back to nested `.env` files outside the fixed root path."""
        repo_root = tmp_path / "repo"
        nested_dir = repo_root / "src" / "prodbox" / "infra"
        nested_dir.mkdir(parents=True)
        _patch_repository_root(monkeypatch, repo_root)
        (nested_dir / ".env").write_text(
            "\n".join(
                [
                    "AWS_ACCESS_KEY_ID=test-access-key",
                    "AWS_SECRET_ACCESS_KEY=test-secret-key",
                    "AWS_SESSION_TOKEN=test-session-token",
                    "ROUTE53_ZONE_ID=Z1234567890ABC",
                    "ACME_EMAIL=test@example.com",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        monkeypatch.chdir(nested_dir)

        with (
            patch.dict(os.environ, {}, clear=True),
            pytest.raises(ValidationError, match="must define AWS auth for prodbox"),
        ):
            Settings()


class TestDisplayDict:
    """Tests for Settings.display_dict() method."""

    def test_returns_non_secret_values(self, settings: Settings) -> None:
        """display_dict should return the supported configuration surface."""
        display = settings.display_dict()

        assert display["aws_region"] == "us-east-1"
        assert display["aws_access_key_id"] == "****-key"
        assert display["aws_secret_access_key"] == "****-key"
        assert display["aws_session_token"] == "****oken"
        assert display["route53_zone_id"] == "Z1234567890ABC"
        assert display["demo_fqdn"] == "test.example.com"
        assert display["acme_email"] == "****.com"

    def test_show_secrets_reveals_sensitive_values(self, settings: Settings) -> None:
        """display_dict(show_secrets=True) should unmask sensitive settings."""
        assert settings.display_dict(show_secrets=True)["aws_access_key_id"] == "test-access-key"
        assert (
            settings.display_dict(show_secrets=True)["aws_secret_access_key"] == "test-secret-key"
        )
        assert settings.display_dict(show_secrets=True)["aws_session_token"] == "test-session-token"
        assert settings.display_dict(show_secrets=True)["acme_email"] == "test@example.com"


class TestRenderedSettings:
    """Tests for deterministic rendered settings output."""

    def test_render_display_lists_supported_settings(self, settings: Settings) -> None:
        """render_display should include masked `.env` AWS auth vars."""
        rendered = settings.render_display()

        assert "AWS_ACCESS_KEY_ID=****-key" in rendered
        assert "AWS_SECRET_ACCESS_KEY=****-key" in rendered
        assert "AWS_SESSION_TOKEN=****oken" in rendered
        assert "AWS_REGION=us-east-1" in rendered
        assert "ROUTE53_ZONE_ID=Z1234567890ABC" in rendered
        assert "ACME_EMAIL=****.com" in rendered

    def test_render_display_show_secrets_reveals_sensitive_values(
        self,
        settings: Settings,
    ) -> None:
        """render_display(show_secrets=True) should unmask sensitive settings."""
        rendered = settings.render_display(show_secrets=True)

        assert "AWS_ACCESS_KEY_ID=test-access-key" in rendered
        assert "AWS_SECRET_ACCESS_KEY=test-secret-key" in rendered
        assert "AWS_SESSION_TOKEN=test-session-token" in rendered
        assert "ACME_EMAIL=test@example.com" in rendered
        assert "ACME_EMAIL=****.com" not in rendered

    def test_render_template_contains_required_and_optional_settings(self) -> None:
        """render_template should list required and optional variables deterministically."""
        template = Settings.render_template()

        assert "# prodbox environment template" in template
        assert "AWS_ACCESS_KEY_ID=" in template
        assert "AWS_SECRET_ACCESS_KEY=" in template
        assert "AWS_SESSION_TOKEN=" in template
        assert "ROUTE53_ZONE_ID=" in template
        assert "AWS_REGION=us-east-1" in template
        assert "BOOTSTRAP_PUBLIC_IP_OVERRIDE=" in template
        assert "PULUMI_ENABLE_DNS_BOOTSTRAP=true" in template


class TestLanDiscoveryHelpers:
    """Tests for adaptive LAN discovery helpers."""

    def test_build_ifreq_returns_fixed_width_buffer(self) -> None:
        """ifreq helper should always emit the kernel-sized buffer."""
        buffer = _build_ifreq("eth0")

        assert len(buffer) == 256
        assert buffer.startswith(b"eth0")

    def test_default_route_interface_name_reads_linux_default_route(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Default-route parsing should return the interface with the gateway flag."""
        route_path = tmp_path / "route"
        route_path.write_text(
            "\n".join(
                [
                    "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT",
                    "lo\t00000000\t00000000\t0001\t0\t0\t0\t00000000\t0\t0\t0",
                    "eno1\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        monkeypatch.setattr(settings_module, "_PROC_ROUTE_PATH", route_path)

        assert _default_route_interface_name() == "eno1"

    def test_select_metallb_range_prefers_canonical_offset_window(self) -> None:
        """A standard /24 should use the canonical .240-.250 window."""
        network = ipaddress.ip_network("192.168.40.0/24")
        interface_ip = ipaddress.ip_address("192.168.40.10")

        metallb_pool, ingress_lb_ip = _select_metallb_range(
            network=network,
            interface_ip=interface_ip,
        )

        assert metallb_pool == "192.168.40.240-192.168.40.250"
        assert ingress_lb_ip == "192.168.40.240"

    def test_select_metallb_range_falls_back_away_from_interface_collision(self) -> None:
        """When the interface IP is inside the preferred window, choose a safe fallback."""
        network = ipaddress.ip_network("192.168.40.0/24")
        interface_ip = ipaddress.ip_address("192.168.40.245")

        metallb_pool, ingress_lb_ip = _select_metallb_range(
            network=network,
            interface_ip=interface_ip,
        )

        assert metallb_pool == "192.168.40.234-192.168.40.244"
        assert ingress_lb_ip == "192.168.40.234"

    def test_select_metallb_range_rejects_tiny_subnet(self) -> None:
        """Tiny subnets should fail fast instead of inventing invalid defaults."""
        network = ipaddress.ip_network("192.168.40.0/29")
        interface_ip = ipaddress.ip_address("192.168.40.2")

        with pytest.raises(ValueError, match="too small"):
            _select_metallb_range(network=network, interface_ip=interface_ip)

    def test_discover_lan_addressing_uses_ioctl_and_default_route(
        self,
    ) -> None:
        """LAN discovery should derive the active subnet and canonical pool."""
        discover_lan_addressing.cache_clear()
        with (
            patch("prodbox.settings._default_route_interface_name", return_value="eno1"),
            patch(
                "prodbox.settings._ioctl_ipv4_value",
                side_effect=["192.168.77.15", "255.255.255.0"],
            ),
        ):
            discovered = discover_lan_addressing()
        discover_lan_addressing.cache_clear()

        assert discovered.interface_name == "eno1"
        assert discovered.interface_ipv4 == "192.168.77.15"
        assert discovered.network_cidr == "192.168.77.0/24"
        assert discovered.metallb_pool == "192.168.77.240-192.168.77.250"
        assert discovered.ingress_lb_ip == "192.168.77.240"

    def test_discover_lan_addressing_or_none_handles_os_error(self) -> None:
        """OSError during discovery should return None for caller fallback handling."""
        with patch("prodbox.settings.discover_lan_addressing", side_effect=OSError("boom")):
            assert _discover_lan_addressing_or_none() is None

    def test_discover_lan_addressing_or_none_handles_value_error(self) -> None:
        """ValueError during discovery should also return None."""
        with patch("prodbox.settings.discover_lan_addressing", side_effect=ValueError("boom")):
            assert _discover_lan_addressing_or_none() is None


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
