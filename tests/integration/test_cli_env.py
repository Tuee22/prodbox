"""Integration tests for CLI env commands."""

from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli


class TestEnvShow:
    """Tests for 'prodbox env show' command."""

    def test_returns_zero_on_valid_config(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """env show should return exit code 0 with valid configuration."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["env", "show"], catch_exceptions=False)

        # The command should succeed (exit code 0) or have rich output
        # With the effect system, success is indicated by exit code
        assert result.exit_code == 0

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

    def test_returns_zero_exit_code(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """env template should return exit code 0."""
        # Template doesn't need valid config
        result = cli_runner.invoke(cli, ["env", "template"], catch_exceptions=False)

        assert result.exit_code == 0
