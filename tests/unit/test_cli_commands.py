"""Unit tests for CLI entry points using Click CliRunner.

Tests verify:
1. CLI commands parse arguments correctly
2. Commands invoke execute_command with correct Command ADT
3. Commands handle Failure results from command constructors
4. Exit codes are properly propagated

Following the Interpreter-Only Mocking Doctrine:
- We mock execute_command at the CLI boundary
- The command_adt functions are tested elsewhere (pure tests)
- CLI tests verify the Click integration layer only
"""

from __future__ import annotations

import contextlib
from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli
from prodbox.cli.test_cmd import (
    ALL_TEST_SUITE,
    INTEGRATION_DNS_AWS_TEST_SUITE,
    INTEGRATION_GATEWAY_PODS_TEST_SUITE,
    INTEGRATION_HA_RKE2_AWS_TEST_SUITE,
    INTEGRATION_PUBLIC_DNS_TEST_SUITE,
    INTEGRATION_PULUMI_TEST_SUITE,
    CoverageSettings,
)


@pytest.fixture
def runner() -> CliRunner:
    """Create a Click CLI test runner."""
    return CliRunner()


# =============================================================================
# Main CLI Tests
# =============================================================================


class TestMainCLI:
    """Tests for main.py CLI entry point."""

    def test_cli_help(self, runner: CliRunner) -> None:
        """CLI should display help text."""
        result = runner.invoke(cli, ["--help"])
        assert result.exit_code == 0
        assert "prodbox" in result.output
        assert "Home Kubernetes cluster management" in result.output

    def test_cli_version(self, runner: CliRunner) -> None:
        """CLI should display version."""
        result = runner.invoke(cli, ["--version"])
        assert result.exit_code == 0
        # Version is extracted from package metadata

    def test_cli_verbose_flag(self, runner: CliRunner) -> None:
        """CLI should accept --verbose flag."""
        # Just invoking help with verbose should work
        result = runner.invoke(cli, ["--verbose", "--help"])
        assert result.exit_code == 0

    def test_cli_v_short_flag(self, runner: CliRunner) -> None:
        """CLI should accept -v short flag."""
        result = runner.invoke(cli, ["-v", "--help"])
        assert result.exit_code == 0


# =============================================================================
# DNS Command Tests
# =============================================================================


class TestDNSCommands:
    """Tests for dns.py CLI commands."""

    def test_dns_group_help(self, runner: CliRunner) -> None:
        """dns group should display help."""
        result = runner.invoke(cli, ["dns", "--help"])
        assert result.exit_code == 0
        assert "DNS inspection commands" in result.output

    def test_dns_check_success(self, runner: CliRunner) -> None:
        """dns check should invoke execute_command."""
        with patch("prodbox.cli.dns.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["dns", "check"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()


# =============================================================================
# Host Command Tests
# =============================================================================


class TestHostCommands:
    """Tests for host.py CLI commands."""

    def test_host_group_help(self, runner: CliRunner) -> None:
        """host group should display help."""
        result = runner.invoke(cli, ["host", "--help"])
        assert result.exit_code == 0
        assert "Host prerequisite management" in result.output

    def test_host_ensure_tools_success(self, runner: CliRunner) -> None:
        """host ensure-tools should invoke execute_command."""
        with patch("prodbox.cli.host.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["host", "ensure-tools"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_host_check_ports_success(self, runner: CliRunner) -> None:
        """host check-ports should invoke execute_command."""
        with patch("prodbox.cli.host.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["host", "check-ports"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_host_info_success(self, runner: CliRunner) -> None:
        """host info should invoke execute_command."""
        with patch("prodbox.cli.host.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["host", "info"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_host_firewall_success(self, runner: CliRunner) -> None:
        """host firewall should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.host.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["host", "firewall"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_host_firewall_command_failure(self, runner: CliRunner) -> None:
        """host firewall should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.host.host_firewall_command",
            return_value=Failure("Firewall check failed"),
        ):
            result = runner.invoke(cli, ["host", "firewall"])

        assert result.exit_code == 1
        assert "Firewall check failed" in result.output

    def test_host_public_edge_success(self, runner: CliRunner) -> None:
        """host public-edge should invoke execute_command."""
        with patch("prodbox.cli.host.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["host", "public-edge"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_host_group_help_lists_public_edge(self, runner: CliRunner) -> None:
        """host --help should advertise the public-edge diagnostic command."""
        result = runner.invoke(cli, ["host", "--help"])

        assert result.exit_code == 0
        assert "public-edge" in result.output


# =============================================================================
# K8s Command Tests
# =============================================================================


class TestK8sCommands:
    """Tests for k8s.py CLI commands."""

    def test_k8s_group_help(self, runner: CliRunner) -> None:
        """k8s group should display help."""
        result = runner.invoke(cli, ["k8s", "--help"])
        assert result.exit_code == 0
        assert "Kubernetes health" in result.output

    def test_k8s_health_success(self, runner: CliRunner) -> None:
        """k8s health should invoke execute_command."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["k8s", "health"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_k8s_wait_success(self, runner: CliRunner) -> None:
        """k8s wait should invoke execute_command."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["k8s", "wait"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_k8s_wait_with_timeout(self, runner: CliRunner) -> None:
        """k8s wait --timeout should pass timeout."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0):
            result = runner.invoke(cli, ["k8s", "wait", "--timeout", "600"])

        assert result.exit_code == 0

    def test_k8s_wait_with_t_flag(self, runner: CliRunner) -> None:
        """k8s wait -t should pass timeout."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0):
            result = runner.invoke(cli, ["k8s", "wait", "-t", "60"])

        assert result.exit_code == 0

    def test_k8s_wait_with_namespace(self, runner: CliRunner) -> None:
        """k8s wait --namespace should pass namespaces."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0):
            result = runner.invoke(cli, ["k8s", "wait", "-n", "kube-system"])

        assert result.exit_code == 0

    def test_k8s_wait_with_multiple_namespaces(self, runner: CliRunner) -> None:
        """k8s wait with multiple --namespace should pass all."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0):
            result = runner.invoke(cli, ["k8s", "wait", "-n", "ns1", "-n", "ns2", "-n", "ns3"])

        assert result.exit_code == 0

    def test_k8s_logs_success(self, runner: CliRunner) -> None:
        """k8s logs should invoke execute_command."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["k8s", "logs"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_k8s_logs_with_tail(self, runner: CliRunner) -> None:
        """k8s logs --tail should pass tail count."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0):
            result = runner.invoke(cli, ["k8s", "logs", "--tail", "100"])

        assert result.exit_code == 0

    def test_k8s_logs_with_namespace(self, runner: CliRunner) -> None:
        """k8s logs --namespace should pass namespaces."""
        with patch("prodbox.cli.k8s.execute_command", return_value=0):
            result = runner.invoke(cli, ["k8s", "logs", "-n", "kube-system"])

        assert result.exit_code == 0


# =============================================================================
# Pulumi Command Tests
# =============================================================================


class TestPulumiCommands:
    """Tests for pulumi_cmd.py CLI commands."""

    def test_pulumi_group_help(self, runner: CliRunner) -> None:
        """pulumi group should display help."""
        result = runner.invoke(cli, ["pulumi", "--help"])
        assert result.exit_code == 0
        assert "Pulumi infrastructure" in result.output

    def test_pulumi_up_success(self, runner: CliRunner) -> None:
        """pulumi up should invoke execute_command."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["pulumi", "up"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_pulumi_up_with_yes(self, runner: CliRunner) -> None:
        """pulumi up --yes should pass yes=True."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0):
            result = runner.invoke(cli, ["pulumi", "up", "--yes"])

        assert result.exit_code == 0

    def test_pulumi_up_with_y_flag(self, runner: CliRunner) -> None:
        """pulumi up -y should pass yes=True."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0):
            result = runner.invoke(cli, ["pulumi", "up", "-y"])

        assert result.exit_code == 0

    def test_pulumi_destroy_success(self, runner: CliRunner) -> None:
        """pulumi destroy should invoke execute_command."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["pulumi", "destroy"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_pulumi_destroy_with_yes(self, runner: CliRunner) -> None:
        """pulumi destroy --yes should pass yes=True."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0):
            result = runner.invoke(cli, ["pulumi", "destroy", "--yes"])

        assert result.exit_code == 0

    def test_pulumi_preview_success(self, runner: CliRunner) -> None:
        """pulumi preview should invoke execute_command."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["pulumi", "preview"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_pulumi_refresh_success(self, runner: CliRunner) -> None:
        """pulumi refresh should invoke execute_command."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["pulumi", "refresh"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_pulumi_stack_init_success(self, runner: CliRunner) -> None:
        """pulumi stack-init should invoke execute_command."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["pulumi", "stack-init", "dev"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_pulumi_stack_init_requires_argument(self, runner: CliRunner) -> None:
        """pulumi stack-init should require stack argument."""
        result = runner.invoke(cli, ["pulumi", "stack-init"])
        assert result.exit_code != 0
        assert "Missing argument" in result.output

    def test_pulumi_test_resources_success(self, runner: CliRunner) -> None:
        """pulumi test-resources should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["pulumi", "test-resources"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_pulumi_test_destroy_requires_yes(self, runner: CliRunner) -> None:
        """pulumi test-destroy should require explicit confirmation."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            result = runner.invoke(cli, ["pulumi", "test-destroy"])

        assert result.exit_code == 1
        assert "--yes" in result.output

    def test_pulumi_test_destroy_with_yes(self, runner: CliRunner) -> None:
        """pulumi test-destroy --yes should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.pulumi_cmd.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["pulumi", "test-destroy", "--yes"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()


# =============================================================================
# Gateway Command Tests
# =============================================================================


class TestGatewayCommands:
    """Tests for gateway.py CLI commands."""

    def test_gateway_group_help(self, runner: CliRunner) -> None:
        """gateway group should display help."""
        result = runner.invoke(cli, ["gateway", "--help"])

        assert result.exit_code == 0
        assert "Gateway daemon management" in result.output
        assert "install-service" not in result.output

    def test_gateway_start_success(self, runner: CliRunner, tmp_path: Path) -> None:
        """gateway start should invoke execute_command."""
        config_path = tmp_path / "gateway.json"
        config_path.write_text("{}", encoding="utf-8")

        with patch("prodbox.cli.gateway.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["gateway", "start", str(config_path)])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_gateway_status_success(self, runner: CliRunner, tmp_path: Path) -> None:
        """gateway status should invoke execute_command."""
        config_path = tmp_path / "gateway.json"
        config_path.write_text("{}", encoding="utf-8")

        with patch("prodbox.cli.gateway.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(cli, ["gateway", "status", str(config_path)])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_gateway_config_gen_success(self, runner: CliRunner, tmp_path: Path) -> None:
        """gateway config-gen should invoke execute_command."""
        output_path = tmp_path / "gateway.json"

        with patch("prodbox.cli.gateway.execute_command", return_value=0) as mock_exec:
            result = runner.invoke(
                cli,
                ["gateway", "config-gen", str(output_path), "--node-id", "node-a"],
            )

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_gateway_install_service_command_removed(self, runner: CliRunner) -> None:
        """install-service must no longer be a registered subcommand."""
        result = runner.invoke(cli, ["gateway", "install-service", "/tmp/whatever.json"])

        assert result.exit_code != 0
        assert "No such command 'install-service'" in result.output


# =============================================================================
# RKE2 Command Tests
# =============================================================================


class TestRKE2Commands:
    """Tests for rke2.py CLI commands."""

    def test_rke2_group_help(self, runner: CliRunner) -> None:
        """rke2 group should display help."""
        result = runner.invoke(cli, ["rke2", "--help"])
        assert result.exit_code == 0
        assert "RKE2 Kubernetes management" in result.output

    def test_rke2_status_success(self, runner: CliRunner) -> None:
        """rke2 status should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["rke2", "status"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_rke2_status_failure_non_linux(self, runner: CliRunner) -> None:
        """rke2 status should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            result = runner.invoke(cli, ["rke2", "status"])

        assert result.exit_code == 1

    def test_rke2_start_success(self, runner: CliRunner) -> None:
        """rke2 start should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["rke2", "start"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_rke2_stop_success(self, runner: CliRunner) -> None:
        """rke2 stop should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["rke2", "stop"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_rke2_restart_success(self, runner: CliRunner) -> None:
        """rke2 restart should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["rke2", "restart"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_rke2_install_success(self, runner: CliRunner) -> None:
        """rke2 install should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["rke2", "install"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_rke2_delete_success_with_yes(self, runner: CliRunner) -> None:
        """rke2 delete --yes should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["rke2", "delete", "--yes"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_rke2_delete_requires_yes(self, runner: CliRunner) -> None:
        """rke2 delete without --yes should fail fast."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            result = runner.invoke(cli, ["rke2", "delete"])

        assert result.exit_code == 1
        assert "--yes" in result.output

    def test_rke2_logs_success(self, runner: CliRunner) -> None:
        """rke2 logs should invoke execute_command on Linux."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0) as mock_exec,
        ):
            result = runner.invoke(cli, ["rke2", "logs"])

        assert result.exit_code == 0
        mock_exec.assert_called_once()

    def test_rke2_logs_with_lines(self, runner: CliRunner) -> None:
        """rke2 logs --lines should pass lines count."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0),
        ):
            result = runner.invoke(cli, ["rke2", "logs", "--lines", "100"])

        assert result.exit_code == 0

    def test_rke2_logs_with_n_flag(self, runner: CliRunner) -> None:
        """rke2 logs -n should pass lines count."""
        with (
            patch("prodbox.cli.command_adt.platform.system", return_value="Linux"),
            patch("prodbox.cli.rke2.execute_command", return_value=0),
        ):
            result = runner.invoke(cli, ["rke2", "logs", "-n", "25"])

        assert result.exit_code == 0


# =============================================================================
# Execute Command Failure Tests
# =============================================================================


class TestExecuteCommandFailures:
    """Tests for execute_command returning non-zero exit codes."""

    def test_k8s_health_execute_failure(self, runner: CliRunner) -> None:
        """k8s health should propagate execute_command failure."""
        with patch("prodbox.cli.k8s.execute_command", return_value=1):
            result = runner.invoke(cli, ["k8s", "health"])

        assert result.exit_code == 1

    def test_pulumi_up_execute_failure(self, runner: CliRunner) -> None:
        """pulumi up should propagate execute_command failure."""
        with patch("prodbox.cli.pulumi_cmd.execute_command", return_value=1):
            result = runner.invoke(cli, ["pulumi", "up"])

        assert result.exit_code == 1


# =============================================================================
# Command Constructor Failure Tests (Failure branches in CLI entry points)
# =============================================================================


class TestCommandConstructorFailures:
    """Tests for command constructor returning Failure.

    These test the Failure branches in CLI entry points that handle
    validation errors from command constructors.
    """

    def test_dns_check_command_failure(self, runner: CliRunner) -> None:
        """dns check should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.dns.dns_check_command",
            return_value=Failure("DNS check failed"),
        ):
            result = runner.invoke(cli, ["dns", "check"])

        assert result.exit_code == 1
        assert "DNS check failed" in result.output

    def test_host_ensure_tools_command_failure(self, runner: CliRunner) -> None:
        """host ensure-tools should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.host.host_ensure_tools_command",
            return_value=Failure("Missing tools"),
        ):
            result = runner.invoke(cli, ["host", "ensure-tools"])

        assert result.exit_code == 1
        assert "Missing tools" in result.output

    def test_host_public_edge_command_failure(self, runner: CliRunner) -> None:
        """host public-edge should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.host.host_public_edge_command",
            return_value=Failure("Edge diagnostic unavailable"),
        ):
            result = runner.invoke(cli, ["host", "public-edge"])

        assert result.exit_code == 1
        assert "Edge diagnostic unavailable" in result.output

    def test_host_check_ports_command_failure(self, runner: CliRunner) -> None:
        """host check-ports should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.host.host_check_ports_command",
            return_value=Failure("Port check failed"),
        ):
            result = runner.invoke(cli, ["host", "check-ports"])

        assert result.exit_code == 1
        assert "Port check failed" in result.output

    def test_host_info_command_failure(self, runner: CliRunner) -> None:
        """host info should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.host.host_info_command",
            return_value=Failure("System info error"),
        ):
            result = runner.invoke(cli, ["host", "info"])

        assert result.exit_code == 1
        assert "System info error" in result.output

    def test_k8s_health_command_failure(self, runner: CliRunner) -> None:
        """k8s health should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.k8s.k8s_health_command",
            return_value=Failure("Cluster unavailable"),
        ):
            result = runner.invoke(cli, ["k8s", "health"])

        assert result.exit_code == 1
        assert "Cluster unavailable" in result.output

    def test_k8s_wait_command_failure(self, runner: CliRunner) -> None:
        """k8s wait should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.k8s.k8s_wait_command",
            return_value=Failure("Wait failed"),
        ):
            result = runner.invoke(cli, ["k8s", "wait"])

        assert result.exit_code == 1
        assert "Wait failed" in result.output

    def test_k8s_logs_command_failure(self, runner: CliRunner) -> None:
        """k8s logs should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.k8s.k8s_logs_command",
            return_value=Failure("Log retrieval failed"),
        ):
            result = runner.invoke(cli, ["k8s", "logs"])

        assert result.exit_code == 1
        assert "Log retrieval failed" in result.output

    def test_pulumi_preview_command_failure(self, runner: CliRunner) -> None:
        """pulumi preview should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.pulumi_cmd.pulumi_preview_command",
            return_value=Failure("Preview failed"),
        ):
            result = runner.invoke(cli, ["pulumi", "preview"])

        assert result.exit_code == 1
        assert "Preview failed" in result.output

    def test_pulumi_up_command_failure(self, runner: CliRunner) -> None:
        """pulumi up should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.pulumi_cmd.pulumi_up_command",
            return_value=Failure("Up failed"),
        ):
            result = runner.invoke(cli, ["pulumi", "up"])

        assert result.exit_code == 1
        assert "Up failed" in result.output

    def test_pulumi_destroy_command_failure(self, runner: CliRunner) -> None:
        """pulumi destroy should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.pulumi_cmd.pulumi_destroy_command",
            return_value=Failure("Destroy failed"),
        ):
            result = runner.invoke(cli, ["pulumi", "destroy"])

        assert result.exit_code == 1
        assert "Destroy failed" in result.output

    def test_pulumi_refresh_command_failure(self, runner: CliRunner) -> None:
        """pulumi refresh should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.pulumi_cmd.pulumi_refresh_command",
            return_value=Failure("Refresh failed"),
        ):
            result = runner.invoke(cli, ["pulumi", "refresh"])

        assert result.exit_code == 1
        assert "Refresh failed" in result.output

    def test_pulumi_stack_init_command_failure(self, runner: CliRunner) -> None:
        """pulumi stack-init should handle command constructor Failure."""
        from prodbox.cli.types import Failure

        with patch(
            "prodbox.cli.pulumi_cmd.pulumi_stack_init_command",
            return_value=Failure("Stack init failed"),
        ):
            result = runner.invoke(cli, ["pulumi", "stack-init", "dev"])

        assert result.exit_code == 1
        assert "Stack init failed" in result.output

    def test_rke2_start_command_failure_non_linux(self, runner: CliRunner) -> None:
        """rke2 start should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            result = runner.invoke(cli, ["rke2", "start"])

        assert result.exit_code == 1

    def test_rke2_stop_command_failure_non_linux(self, runner: CliRunner) -> None:
        """rke2 stop should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            result = runner.invoke(cli, ["rke2", "stop"])

        assert result.exit_code == 1

    def test_rke2_restart_command_failure_non_linux(self, runner: CliRunner) -> None:
        """rke2 restart should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            result = runner.invoke(cli, ["rke2", "restart"])

        assert result.exit_code == 1

    def test_rke2_install_command_failure_non_linux(self, runner: CliRunner) -> None:
        """rke2 install should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            result = runner.invoke(cli, ["rke2", "install"])

        assert result.exit_code == 1

    def test_rke2_logs_command_failure_non_linux(self, runner: CliRunner) -> None:
        """rke2 logs should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            result = runner.invoke(cli, ["rke2", "logs"])

        assert result.exit_code == 1

    def test_rke2_delete_command_failure_non_linux(self, runner: CliRunner) -> None:
        """rke2 delete should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            result = runner.invoke(cli, ["rke2", "delete", "--yes"])

        assert result.exit_code == 1


# =============================================================================
# Main Entry Point Test
# =============================================================================


class TestMainEntryPoint:
    """Tests for main.py main() function."""

    def test_main_function_calls_cli(self, runner: CliRunner) -> None:  # noqa: ARG002
        """main() should call cli()."""
        from prodbox.cli.main import main

        with patch("prodbox.cli.main.cli") as mock_cli:
            # main() calls cli() which is a Click command
            # We just verify it's called
            with contextlib.suppress(SystemExit):
                main()

            mock_cli.assert_called_once()


class TestClickDocumentation:
    """Tests for Click help coverage of the explicit command surface."""

    @pytest.mark.parametrize(
        ("argv", "tokens", "expected_exit_code"),
        [
            (["--help"], ("check-code", "gateway", "test", "tla-check"), 0),
            (["host"], ("check-ports", "ensure-tools", "firewall", "info"), 2),
            (
                ["rke2"],
                ("delete", "install", "logs", "restart", "start", "status", "stop"),
                2,
            ),
            (["rke2", "delete", "--help"], ("--yes",), 0),
            (["rke2", "logs", "--help"], ("--lines",), 0),
            (
                ["pulumi"],
                (
                    "destroy",
                    "preview",
                    "refresh",
                    "stack-init",
                    "test-destroy",
                    "test-resources",
                    "up",
                ),
                2,
            ),
            (["pulumi", "up", "--help"], ("--yes",), 0),
            (["pulumi", "stack-init", "--help"], ("STACK",), 0),
            (["dns"], ("check",), 2),
            (["dns", "check", "--help"], (), 0),
            (["k8s"], ("health", "logs", "wait"), 2),
            (["k8s", "wait", "--help"], ("--timeout", "--namespace"), 0),
            (["k8s", "logs", "--help"], ("--namespace", "--tail"), 0),
            (["gateway"], ("config-gen", "start", "status"), 2),
            (["gateway", "start", "--help"], ("CONFIG_PATH",), 0),
            (["gateway", "config-gen", "--help"], ("OUTPUT_PATH", "--node-id"), 0),
            (["test"], ("all", "integration", "unit"), 2),
            (["test", "all", "--help"], ("--coverage", "--cov-fail-under"), 0),
            (
                ["test", "integration"],
                (
                    "all",
                    "cli",
                    "dns-aws",
                    "env",
                    "gateway-daemon",
                    "gateway-pods",
                    "ha-rke2-aws",
                    "lifecycle",
                    "pulumi",
                    "public-dns",
                ),
                2,
            ),
            (
                ["test", "integration", "gateway-pods", "--help"],
                ("--coverage", "--cov-fail-under"),
                0,
            ),
            (["check-code", "--help"], ("Run policy",), 0),
            (["tla-check", "--help"], ("Run the TLA+ model checker via Docker.",), 0),
        ],
    )
    def test_click_help_lists_supported_commands_and_parameters(
        self,
        runner: CliRunner,
        argv: list[str],
        tokens: tuple[str, ...],
        expected_exit_code: int,
    ) -> None:
        """Help output should enumerate the legal commands and parameters."""
        result = runner.invoke(cli, argv)
        assert result.exit_code == expected_exit_code
        for token in tokens:
            assert token in result.output


class TestTestCommandSurface:
    """Tests for the explicit `prodbox test` Click surface."""

    def test_test_all_invokes_named_suite_with_coverage(self, runner: CliRunner) -> None:
        """`prodbox test all` should dispatch the full suite with explicit coverage settings."""
        with patch("prodbox.cli.test_cmd._run_suite", return_value=0) as mock_run_suite:
            result = runner.invoke(
                cli,
                ["test", "all", "--coverage", "--cov-fail-under", "95"],
            )

        assert result.exit_code == 0
        mock_run_suite.assert_called_once_with(
            suite=ALL_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=True, fail_under=95),
        )

    def test_test_integration_gateway_pods_invokes_named_suite(self, runner: CliRunner) -> None:
        """Named integration suite commands should dispatch their explicit suite mapping."""
        with patch("prodbox.cli.test_cmd._run_suite", return_value=0) as mock_run_suite:
            result = runner.invoke(cli, ["test", "integration", "gateway-pods"])

        assert result.exit_code == 0
        mock_run_suite.assert_called_once_with(
            suite=INTEGRATION_GATEWAY_PODS_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=False, fail_under=None),
        )

    def test_test_integration_dns_aws_invokes_named_suite(self, runner: CliRunner) -> None:
        """dns-aws should dispatch the explicit Route 53 integration suite."""
        with patch("prodbox.cli.test_cmd._run_suite", return_value=0) as mock_run_suite:
            result = runner.invoke(cli, ["test", "integration", "dns-aws"])

        assert result.exit_code == 0
        mock_run_suite.assert_called_once_with(
            suite=INTEGRATION_DNS_AWS_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=False, fail_under=None),
        )

    def test_test_integration_ha_rke2_aws_invokes_named_suite(self, runner: CliRunner) -> None:
        """ha-rke2-aws should dispatch the canonical SSH-driven AWS HA RKE2 suite."""
        with patch("prodbox.cli.test_cmd._run_suite", return_value=0) as mock_run_suite:
            result = runner.invoke(cli, ["test", "integration", "ha-rke2-aws"])

        assert result.exit_code == 0
        mock_run_suite.assert_called_once_with(
            suite=INTEGRATION_HA_RKE2_AWS_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=False, fail_under=None),
        )

    def test_test_integration_pulumi_invokes_named_suite(self, runner: CliRunner) -> None:
        """pulumi should dispatch the explicit real Pulumi integration suite."""
        with patch("prodbox.cli.test_cmd._run_suite", return_value=0) as mock_run_suite:
            result = runner.invoke(cli, ["test", "integration", "pulumi"])

        assert result.exit_code == 0
        mock_run_suite.assert_called_once_with(
            suite=INTEGRATION_PULUMI_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=False, fail_under=None),
        )

    def test_test_integration_public_dns_invokes_named_suite(self, runner: CliRunner) -> None:
        """public-dns should dispatch the explicit public delegation suite."""
        with patch("prodbox.cli.test_cmd._run_suite", return_value=0) as mock_run_suite:
            result = runner.invoke(cli, ["test", "integration", "public-dns"])

        assert result.exit_code == 0
        mock_run_suite.assert_called_once_with(
            suite=INTEGRATION_PUBLIC_DNS_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=False, fail_under=None),
        )

    def test_test_command_rejects_unexpected_extra_arguments(self, runner: CliRunner) -> None:
        """Extra args should fail at the Click boundary instead of reaching pytest."""
        result = runner.invoke(cli, ["test", "all", "extra"])
        assert result.exit_code == 2
        assert "Got unexpected extra argument" in result.output

    def test_test_command_rejects_threshold_without_coverage(self, runner: CliRunner) -> None:
        """Coverage thresholds require the explicit coverage flag."""
        result = runner.invoke(cli, ["test", "unit", "--cov-fail-under", "100"])
        assert result.exit_code == 2
        assert "--cov-fail-under requires --coverage" in result.output
