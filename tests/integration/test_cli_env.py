"""Integration tests for CLI env commands."""

from __future__ import annotations

import os
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli


class TestEnvShow:
    """Tests for 'prodbox env show' command."""

    def test_shows_configuration(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show should display current configuration."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "show"])

        assert result.exit_code == 0
        assert "test.example.com" in result.output
        assert "us-east-1" in result.output

    def test_masks_secrets_by_default(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show should mask secrets by default."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "show"])

        assert result.exit_code == 0
        assert "****" in result.output
        # Full secret should not appear
        assert "test-secret-access-key" not in result.output

    def test_shows_secrets_with_flag(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show --show-secrets should display full secrets."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "show", "--show-secrets"])

        assert result.exit_code == 0
        assert "test-secret-access-key" in result.output

    def test_fails_with_missing_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """env show should fail with missing required config."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["env", "show"])

        assert result.exit_code == 1
        assert "validation failed" in result.output.lower()


class TestEnvValidate:
    """Tests for 'prodbox env validate' command."""

    def test_validates_good_config(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env validate should pass with valid configuration."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "validate"])

        assert result.exit_code == 0
        assert "valid" in result.output.lower()

    def test_shows_config_summary(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env validate should show configuration summary."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "validate"])

        assert result.exit_code == 0
        assert "test.example.com" in result.output
        assert "us-east-1" in result.output

    def test_fails_with_invalid_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """env validate should fail with invalid configuration."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["env", "validate"])

        assert result.exit_code == 1
        assert "validation failed" in result.output.lower()


class TestEnvTemplate:
    """Tests for 'prodbox env template' command."""

    def test_outputs_template(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """env template should output a .env template."""
        # Template doesn't need valid config
        result = cli_runner.invoke(cli, ["env", "template"])

        assert result.exit_code == 0
        assert "AWS_ACCESS_KEY_ID" in result.output
        assert "AWS_SECRET_ACCESS_KEY" in result.output
        assert "ROUTE53_ZONE_ID" in result.output
        assert "ACME_EMAIL" in result.output
