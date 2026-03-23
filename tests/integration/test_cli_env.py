"""Integration tests for CLI env commands."""

from __future__ import annotations

import os
from unittest.mock import patch

from click.testing import CliRunner

from prodbox.cli.main import cli


class TestEnvShow:
    """Tests for 'prodbox env show' command."""

    def test_prints_masked_configuration_on_valid_config(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show should print effective configuration with masked secrets."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "show"], catch_exceptions=False)

        assert result.exit_code == 0
        assert "AWS_ACCESS_KEY_ID=test-access-key-id" in result.output
        assert "AWS_SECRET_ACCESS_KEY=****-key" in result.output
        assert "AWS_SECRET_ACCESS_KEY=test-secret-access-key" not in result.output

    def test_show_secrets_exposes_full_secret_value(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show --show-secrets should expose the configured secret."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(
                cli,
                ["env", "show", "--show-secrets"],
                catch_exceptions=False,
            )

        assert result.exit_code == 0
        assert "AWS_SECRET_ACCESS_KEY=test-secret-access-key" in result.output

    def test_fails_with_missing_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """env show should fail with missing required config."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["env", "show"])

        assert result.exit_code == 1


class TestEnvValidate:
    """Tests for 'prodbox env validate' command."""

    def test_validates_good_config(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env validate should pass with valid configuration."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "validate"], catch_exceptions=False)

        assert result.exit_code == 0

    def test_fails_with_invalid_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """env validate should fail with invalid configuration."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["env", "validate"])

        assert result.exit_code == 1


class TestEnvTemplate:
    """Tests for 'prodbox env template' command."""

    def test_prints_template_content(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """env template should print required and optional settings."""
        result = cli_runner.invoke(cli, ["env", "template"], catch_exceptions=False)

        assert result.exit_code == 0
        assert "# prodbox environment template" in result.output
        assert "AWS_ACCESS_KEY_ID=" in result.output
        assert "AWS_REGION=us-east-1" in result.output
        assert "BOOTSTRAP_PUBLIC_IP_OVERRIDE=" in result.output
