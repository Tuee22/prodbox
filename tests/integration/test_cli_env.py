"""Integration tests for CLI config commands."""

from __future__ import annotations

import os
from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

import prodbox.settings as settings_module
from prodbox.cli.main import cli


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
