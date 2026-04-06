"""Integration tests for CLI env commands."""

from __future__ import annotations

import os
from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli


def _write_aws_auth_dotenv(tmp_path: Path) -> None:
    """Write minimal `.env` AWS auth required by CLI settings validation."""
    (tmp_path / ".env").write_text(
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


class TestEnvShow:
    """Tests for 'prodbox env show' command."""

    def test_prints_masked_configuration_on_valid_config(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show should print effective configuration with masked `.env` AWS auth."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "show"], catch_exceptions=False)

        assert result.exit_code == 0
        assert "AWS_ACCESS_KEY_ID=****-key" in result.output
        assert "AWS_SECRET_ACCESS_KEY=****-key" in result.output
        assert "AWS_SESSION_TOKEN=****oken" in result.output
        assert "ROUTE53_ZONE_ID=Z1234567890ABC" in result.output
        assert "ACME_EMAIL=****.com" in result.output
        assert "ACME_EMAIL=test@example.com" not in result.output

    def test_show_secrets_reveals_sensitive_values(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show --show-secrets should reveal the full sensitive values."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(
                cli,
                ["env", "show", "--show-secrets"],
                catch_exceptions=False,
            )

        assert result.exit_code == 0
        assert "AWS_ACCESS_KEY_ID=test-access-key" in result.output
        assert "AWS_SECRET_ACCESS_KEY=test-secret-key" in result.output
        assert "AWS_SESSION_TOKEN=test-session-token" in result.output
        assert "ROUTE53_ZONE_ID=Z1234567890ABC" in result.output
        assert "ACME_EMAIL=test@example.com" in result.output
        assert "ACME_EMAIL=****.com" not in result.output

    def test_fails_with_missing_config(
        self,
        cli_runner: CliRunner,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """env show should fail with missing required config."""
        _write_aws_auth_dotenv(tmp_path)
        monkeypatch.chdir(tmp_path)
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
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """env validate should fail with invalid configuration."""
        _write_aws_auth_dotenv(tmp_path)
        monkeypatch.chdir(tmp_path)
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["env", "validate"])

        assert result.exit_code == 1

    def test_rejects_forbidden_aws_auth_env_vars(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env validate should fail fast when ambient AWS auth env vars are present."""
        env = {**mock_env, "AWS_ACCESS_KEY_ID": "forbidden"}
        with patch.dict(os.environ, env, clear=True):
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
        assert "AWS_SECRET_ACCESS_KEY=" in result.output
        assert "AWS_SESSION_TOKEN=" in result.output
        assert "AWS_REGION=us-east-1" in result.output
        assert "ROUTE53_ZONE_ID=" in result.output
        assert "BOOTSTRAP_PUBLIC_IP_OVERRIDE=" in result.output
