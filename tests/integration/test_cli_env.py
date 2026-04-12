"""Integration tests for CLI config commands."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

import prodbox.settings as settings_module
from prodbox.cli.main import cli


def _compiled_config_json_bytes() -> bytes:
    """Return one valid compiled-config payload for CLI auto-compile tests."""
    config: dict[str, object] = {
        "aws": {
            "access_key_id": "test-access-key",
            "secret_access_key": "test-secret-key",
            "session_token": "test-session-token",
            "region": "us-east-1",
        },
        "route53": {"zone_id": "Z1234567890ABC"},
        "domain": {
            "demo_fqdn": "test.example.com",
            "demo_ttl": 60,
            "vscode_fqdn": None,
        },
        "acme": {
            "email": "test@example.com",
            "server": "https://acme-staging-v02.api.letsencrypt.org/directory",
            "eab_key_id": None,
            "eab_hmac_key": None,
        },
        "deployment": {
            "dev_mode": True,
            "bootstrap_public_ip_override": None,
            "pulumi_enable_dns_bootstrap": True,
        },
    }
    return json.dumps(config, indent=2).encode("utf-8")


class TestConfigShow:
    """Tests for 'prodbox config show' command."""

    def test_prints_masked_configuration_on_valid_config(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """config show should print effective configuration with masked secrets."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["config", "show"], catch_exceptions=False)

        assert result.exit_code == 0
        assert "aws.access_key_id=****-key" in result.output
        assert "aws.secret_access_key=****-key" in result.output
        assert "aws.session_token=****oken" in result.output
        assert "route53.zone_id=Z1234567890ABC" in result.output
        assert "acme.email=****.com" in result.output
        assert "acme.email=test@example.com" not in result.output

    def test_show_secrets_reveals_sensitive_values(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """config show --show-secrets should reveal the full sensitive values."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(
                cli,
                ["config", "show", "--show-secrets"],
                catch_exceptions=False,
            )

        assert result.exit_code == 0
        assert "aws.access_key_id=test-access-key" in result.output
        assert "aws.secret_access_key=test-secret-key" in result.output
        assert "aws.session_token=test-session-token" in result.output
        assert "route53.zone_id=Z1234567890ABC" in result.output
        assert "acme.email=test@example.com" in result.output
        assert "acme.email=****.com" not in result.output

    def test_fails_with_missing_config(
        self,
        cli_runner: CliRunner,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """config show should fail with missing config JSON."""
        monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
        monkeypatch.chdir(tmp_path)
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["config", "show"])

        assert result.exit_code == 1

    def test_auto_compiles_dhall_when_repo_json_is_missing(
        self,
        cli_runner: CliRunner,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """config show should auto-compile the canonical Dhall config when needed."""
        monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
        monkeypatch.chdir(tmp_path)
        (tmp_path / "prodbox-config.dhall").write_text("{ dhall = True }\n", encoding="utf-8")
        compile_result = subprocess.CompletedProcess(
            args=("dhall-to-json",),
            returncode=0,
            stdout=_compiled_config_json_bytes(),
            stderr=b"",
        )

        with (
            patch.dict(os.environ, {}, clear=True),
            patch("prodbox.settings.subprocess.run", return_value=compile_result) as compile_mock,
        ):
            result = cli_runner.invoke(cli, ["config", "show"], catch_exceptions=False)

        assert result.exit_code == 0
        assert "route53.zone_id=Z1234567890ABC" in result.output
        assert (tmp_path / "prodbox-config.json").exists()
        compile_mock.assert_called_once()


class TestConfigValidate:
    """Tests for 'prodbox config validate' command."""

    def test_validates_good_config(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """config validate should pass with valid configuration."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["config", "validate"], catch_exceptions=False)

        assert result.exit_code == 0

    def test_fails_with_invalid_config(
        self,
        cli_runner: CliRunner,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """config validate should fail with missing config JSON."""
        monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
        monkeypatch.chdir(tmp_path)
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["config", "validate"])

        assert result.exit_code == 1

    def test_validate_auto_compiles_dhall_when_repo_json_is_missing(
        self,
        cli_runner: CliRunner,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """config validate should auto-compile the canonical Dhall config when needed."""
        monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
        monkeypatch.chdir(tmp_path)
        (tmp_path / "prodbox-config.dhall").write_text("{ dhall = True }\n", encoding="utf-8")
        compile_result = subprocess.CompletedProcess(
            args=("dhall-to-json",),
            returncode=0,
            stdout=_compiled_config_json_bytes(),
            stderr=b"",
        )

        with (
            patch.dict(os.environ, {}, clear=True),
            patch("prodbox.settings.subprocess.run", return_value=compile_result) as compile_mock,
        ):
            result = cli_runner.invoke(cli, ["config", "validate"], catch_exceptions=False)

        assert result.exit_code == 0
        assert (tmp_path / "prodbox-config.json").exists()
        compile_mock.assert_called_once()
