"""Unit tests for Phase 7 settings and config flattening."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

import prodbox.settings as settings_module
from prodbox.settings import Settings, _flatten_config_json


def _phase7_config_json(overrides: dict[str, object] | None = None) -> dict[str, object]:
    """Return one valid config mapping including the optional `aws_admin` section."""
    config: dict[str, object] = {
        "aws": {
            "access_key_id": "test-access-key",
            "secret_access_key": "test-secret-key",
            "session_token": None,
            "region": "us-east-1",
        },
        "aws_admin": {
            "access_key_id": "admin-access-key",
            "secret_access_key": "admin-secret-key",
            "session_token": "admin-session-token",
            "region": "us-east-1",
        },
        "route53": {"zone_id": "Z1234567890ABC"},
        "domain": {
            "demo_fqdn": "demo.example.com",
            "demo_ttl": 60,
            "vscode_fqdn": "vscode.example.com",
        },
        "acme": {
            "email": "ops@example.com",
            "server": "https://acme-v02.api.letsencrypt.org/directory",
            "eab_key_id": None,
            "eab_hmac_key": None,
        },
        "deployment": {
            "dev_mode": True,
            "bootstrap_public_ip_override": None,
            "pulumi_enable_dns_bootstrap": True,
        },
        "storage": {"manual_pv_host_root": ".data"},
    }
    if overrides is not None:
        config.update(overrides)
    return config


class TestPhase7Settings:
    """Tests for optional `aws_admin` settings support."""

    def test_flatten_config_json_maps_admin_fields(self) -> None:
        """Flattening should project the optional `aws_admin` section onto flat settings fields."""
        flat = _flatten_config_json(_phase7_config_json())

        assert flat["aws_admin_access_key_id"] == "admin-access-key"
        assert flat["aws_admin_secret_access_key"] == "admin-secret-key"
        assert flat["aws_admin_session_token"] == "admin-session-token"
        assert flat["aws_admin_region"] == "us-east-1"

    def test_flatten_config_json_tolerates_missing_admin_section(self) -> None:
        """Pre-Phase-7 config JSON without `aws_admin` should still load cleanly."""
        flat = _flatten_config_json(_phase7_config_json({"aws_admin": None}))

        assert flat["aws_admin_access_key_id"] is None
        assert flat["aws_admin_secret_access_key"] is None
        assert flat["aws_admin_session_token"] is None
        assert flat["aws_admin_region"] is None

    def test_settings_reject_partial_admin_credentials(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """`aws_admin` should require access key, secret, and region together when configured."""
        monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
        monkeypatch.chdir(tmp_path)
        (tmp_path / "prodbox-config.json").write_text(
            json.dumps(
                _phase7_config_json(
                    {
                        "aws_admin": {
                            "access_key_id": "admin-access-key",
                            "secret_access_key": "admin-secret-key",
                            "session_token": None,
                            "region": "",
                        }
                    }
                ),
                indent=2,
            ),
            encoding="utf-8",
        )

        with pytest.raises(ValidationError, match="aws_admin.access_key_id"):
            Settings.from_config_json()

    def test_settings_render_display_masks_admin_secrets(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Config display should include and mask the new admin secret fields by default."""
        monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
        monkeypatch.chdir(tmp_path)
        (tmp_path / "prodbox-config.json").write_text(
            json.dumps(_phase7_config_json(), indent=2),
            encoding="utf-8",
        )

        rendered = Settings.from_config_json().render_display()

        assert "aws_admin.access_key_id=****-key" in rendered
        assert "aws_admin.secret_access_key=****-key" in rendered
        assert "aws_admin.session_token=****oken" in rendered
        assert "aws_admin.region=us-east-1" in rendered
