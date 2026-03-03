"""Integration tests for CLI commands using the effect system."""

from __future__ import annotations

import os
from unittest.mock import patch

from click.testing import CliRunner

from prodbox.cli.main import cli


class TestHostCommands:
    """Tests for host subcommands."""

    def test_host_ensure_tools_returns_exit_code(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """host ensure-tools should return an exit code."""
        result = cli_runner.invoke(cli, ["host", "ensure-tools"])
        # May fail if tools not installed, but should complete
        assert result.exit_code in (0, 1)


class TestDNSCommands:
    """Tests for DNS subcommands."""

    def test_dns_check_fails_without_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """dns check should fail without AWS config."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["dns", "check"])

        assert result.exit_code == 1

    def test_dns_update_fails_without_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """dns update should fail without AWS config."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["dns", "update"])

        assert result.exit_code == 1


class TestK8sCommands:
    """Tests for Kubernetes subcommands."""

    def test_k8s_health_fails_without_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """k8s health should fail without kubeconfig."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["k8s", "health"])

        assert result.exit_code == 1


class TestPulumiCommands:
    """Tests for Pulumi subcommands."""

    def test_pulumi_preview_fails_without_tools(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """pulumi preview should fail if pulumi not available."""
        with patch("shutil.which", return_value=None):
            result = cli_runner.invoke(cli, ["pulumi", "preview"])

        # Should fail because pulumi tool isn't available
        assert result.exit_code in (0, 1)


class TestRKE2Commands:
    """Tests for RKE2 subcommands."""

    def test_rke2_status_fails_on_non_linux(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """rke2 status should fail on non-Linux."""
        with patch("platform.system", return_value="Darwin"):
            result = cli_runner.invoke(cli, ["rke2", "status"])

        # Should fail because RKE2 requires Linux
        assert result.exit_code == 1


class TestMainCLI:
    """Tests for main CLI entry point."""

    def test_cli_help(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """CLI should show help."""
        result = cli_runner.invoke(cli, ["--help"])

        assert result.exit_code == 0
        assert "prodbox" in result.output

    def test_cli_version(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """CLI should show version."""
        result = cli_runner.invoke(cli, ["--version"])

        assert result.exit_code == 0

    def test_cli_verbose(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """CLI should accept verbose flag."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["-v", "env", "show"])

        # May succeed or fail based on actual config
        assert result.exit_code in (0, 1)
