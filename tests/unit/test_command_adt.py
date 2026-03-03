"""Unit tests for command ADT module."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from prodbox.cli.command_adt import (
    # Command types
    DNSCheckCommand,
    DNSEnsureTimerCommand,
    DNSUpdateCommand,
    EnvShowCommand,
    EnvTemplateCommand,
    EnvValidateCommand,
    GatewayConfigGenCommand,
    GatewayStartCommand,
    GatewayStatusCommand,
    HostCheckPortsCommand,
    HostEnsureToolsCommand,
    HostFirewallCommand,
    HostInfoCommand,
    K8sHealthCommand,
    K8sLogsCommand,
    K8sWaitCommand,
    PulumiDestroyCommand,
    PulumiPreviewCommand,
    PulumiRefreshCommand,
    PulumiStackInitCommand,
    PulumiUpCommand,
    RKE2EnsureCommand,
    RKE2LogsCommand,
    RKE2RestartCommand,
    RKE2StartCommand,
    RKE2StatusCommand,
    RKE2StopCommand,
    # Smart constructors
    dns_check_command,
    dns_ensure_timer_command,
    dns_update_command,
    env_show_command,
    env_template_command,
    env_validate_command,
    gateway_config_gen_command,
    gateway_start_command,
    gateway_status_command,
    host_check_ports_command,
    host_ensure_tools_command,
    host_firewall_command,
    host_info_command,
    # Utility functions
    is_linux,
    k8s_health_command,
    k8s_logs_command,
    k8s_wait_command,
    pulumi_destroy_command,
    pulumi_preview_command,
    pulumi_refresh_command,
    pulumi_stack_init_command,
    pulumi_up_command,
    requires_linux,
    requires_settings,
    rke2_ensure_command,
    rke2_logs_command,
    rke2_restart_command,
    rke2_start_command,
    rke2_status_command,
    rke2_stop_command,
)
from prodbox.cli.types import Failure, Success


class TestEnvCommands:
    """Tests for environment command smart constructors."""

    def test_env_show_command_default(self) -> None:
        """env_show_command should create command with defaults."""
        match env_show_command():
            case Success(cmd):
                assert isinstance(cmd, EnvShowCommand)
                assert cmd.show_secrets is False
            case Failure(_):
                pytest.fail("Expected Success")

    def test_env_show_command_with_secrets(self) -> None:
        """env_show_command should set show_secrets."""
        match env_show_command(show_secrets=True):
            case Success(cmd):
                assert cmd.show_secrets is True
            case Failure(_):
                pytest.fail("Expected Success")

    def test_env_validate_command(self) -> None:
        """env_validate_command should create command."""
        match env_validate_command():
            case Success(cmd):
                assert isinstance(cmd, EnvValidateCommand)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_env_template_command_default(self) -> None:
        """env_template_command should use default path."""
        match env_template_command():
            case Success(cmd):
                assert isinstance(cmd, EnvTemplateCommand)
                assert cmd.output_path == Path(".env.template")
            case Failure(_):
                pytest.fail("Expected Success")

    def test_env_template_command_custom_path(self) -> None:
        """env_template_command should accept custom path."""
        match env_template_command(output_path=Path("/tmp/custom.env")):
            case Success(cmd):
                assert cmd.output_path == Path("/tmp/custom.env")
            case Failure(_):
                pytest.fail("Expected Success")


class TestHostCommands:
    """Tests for host command smart constructors."""

    def test_host_info_command(self) -> None:
        """host_info_command should create command."""
        match host_info_command():
            case Success(cmd):
                assert isinstance(cmd, HostInfoCommand)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_host_check_ports_command_default(self) -> None:
        """host_check_ports_command should use default ports."""
        match host_check_ports_command():
            case Success(cmd):
                assert isinstance(cmd, HostCheckPortsCommand)
                assert cmd.ports == (80, 443, 6443, 9345)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_host_check_ports_command_custom(self) -> None:
        """host_check_ports_command should accept custom ports."""
        match host_check_ports_command(ports=[8080, 8443]):
            case Success(cmd):
                assert cmd.ports == (8080, 8443)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_host_check_ports_command_invalid(self) -> None:
        """host_check_ports_command should reject invalid ports."""
        match host_check_ports_command(ports=[0, 70000]):
            case Success(_):
                pytest.fail("Expected Failure for invalid ports")
            case Failure(error):
                assert "Invalid port numbers" in error
                assert "0" in error
                assert "70000" in error

    def test_host_ensure_tools_command(self) -> None:
        """host_ensure_tools_command should create command."""
        match host_ensure_tools_command():
            case Success(cmd):
                assert isinstance(cmd, HostEnsureToolsCommand)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_host_firewall_command(self) -> None:
        """host_firewall_command should create command."""
        match host_firewall_command():
            case Success(cmd):
                assert isinstance(cmd, HostFirewallCommand)
            case Failure(_):
                pytest.fail("Expected Success")


class TestRKE2Commands:
    """Tests for RKE2 command smart constructors."""

    def test_rke2_status_command_on_linux(self) -> None:
        """rke2_status_command should succeed on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match rke2_status_command():
                case Success(cmd):
                    assert isinstance(cmd, RKE2StatusCommand)
                case Failure(_):
                    pytest.fail("Expected Success on Linux")

    def test_rke2_status_command_on_non_linux(self) -> None:
        """rke2_status_command should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            match rke2_status_command():
                case Success(_):
                    pytest.fail("Expected Failure on non-Linux")
                case Failure(error):
                    assert "Linux" in error

    def test_rke2_start_command_on_linux(self) -> None:
        """rke2_start_command should succeed on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match rke2_start_command():
                case Success(cmd):
                    assert isinstance(cmd, RKE2StartCommand)
                case Failure(_):
                    pytest.fail("Expected Success on Linux")

    def test_rke2_start_command_on_non_linux(self) -> None:
        """rke2_start_command should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            match rke2_start_command():
                case Success(_):
                    pytest.fail("Expected Failure on non-Linux")
                case Failure(error):
                    assert "Linux" in error

    def test_rke2_stop_command_on_linux(self) -> None:
        """rke2_stop_command should succeed on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match rke2_stop_command():
                case Success(cmd):
                    assert isinstance(cmd, RKE2StopCommand)
                case Failure(_):
                    pytest.fail("Expected Success on Linux")

    def test_rke2_stop_command_on_non_linux(self) -> None:
        """rke2_stop_command should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            match rke2_stop_command():
                case Success(_):
                    pytest.fail("Expected Failure on non-Linux")
                case Failure(error):
                    assert "Linux" in error

    def test_rke2_restart_command_on_linux(self) -> None:
        """rke2_restart_command should succeed on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match rke2_restart_command():
                case Success(cmd):
                    assert isinstance(cmd, RKE2RestartCommand)
                case Failure(_):
                    pytest.fail("Expected Success on Linux")

    def test_rke2_restart_command_on_non_linux(self) -> None:
        """rke2_restart_command should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            match rke2_restart_command():
                case Success(_):
                    pytest.fail("Expected Failure on non-Linux")
                case Failure(error):
                    assert "Linux" in error

    def test_rke2_ensure_command_on_linux(self) -> None:
        """rke2_ensure_command should succeed on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match rke2_ensure_command():
                case Success(cmd):
                    assert isinstance(cmd, RKE2EnsureCommand)
                case Failure(_):
                    pytest.fail("Expected Success on Linux")

    def test_rke2_ensure_command_on_non_linux(self) -> None:
        """rke2_ensure_command should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            match rke2_ensure_command():
                case Success(_):
                    pytest.fail("Expected Failure on non-Linux")
                case Failure(error):
                    assert "Linux" in error

    def test_rke2_logs_command_on_linux(self) -> None:
        """rke2_logs_command should succeed on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match rke2_logs_command(lines=100):
                case Success(cmd):
                    assert isinstance(cmd, RKE2LogsCommand)
                    assert cmd.lines == 100
                case Failure(_):
                    pytest.fail("Expected Success on Linux")

    def test_rke2_logs_command_invalid_lines(self) -> None:
        """rke2_logs_command should reject invalid lines."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match rke2_logs_command(lines=0):
                case Success(_):
                    pytest.fail("Expected Failure for invalid lines")
                case Failure(error):
                    assert "at least 1" in error


class TestDNSCommands:
    """Tests for DNS command smart constructors."""

    def test_dns_check_command(self) -> None:
        """dns_check_command should create command."""
        match dns_check_command():
            case Success(cmd):
                assert isinstance(cmd, DNSCheckCommand)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_dns_update_command_default(self) -> None:
        """dns_update_command should create command with defaults."""
        match dns_update_command():
            case Success(cmd):
                assert isinstance(cmd, DNSUpdateCommand)
                assert cmd.force is False
            case Failure(_):
                pytest.fail("Expected Success")

    def test_dns_update_command_force(self) -> None:
        """dns_update_command should accept force flag."""
        match dns_update_command(force=True):
            case Success(cmd):
                assert cmd.force is True
            case Failure(_):
                pytest.fail("Expected Success")

    def test_dns_ensure_timer_command_on_linux(self) -> None:
        """dns_ensure_timer_command should succeed on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match dns_ensure_timer_command(interval=10):
                case Success(cmd):
                    assert isinstance(cmd, DNSEnsureTimerCommand)
                    assert cmd.interval == 10
                case Failure(_):
                    pytest.fail("Expected Success on Linux")

    def test_dns_ensure_timer_command_on_non_linux(self) -> None:
        """dns_ensure_timer_command should fail on non-Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            match dns_ensure_timer_command():
                case Success(_):
                    pytest.fail("Expected Failure on non-Linux")
                case Failure(error):
                    assert "Linux" in error

    def test_dns_ensure_timer_command_invalid_interval(self) -> None:
        """dns_ensure_timer_command should reject invalid interval."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            match dns_ensure_timer_command(interval=0):
                case Success(_):
                    pytest.fail("Expected Failure for invalid interval")
                case Failure(error):
                    assert "at least 1" in error


class TestK8sCommands:
    """Tests for Kubernetes command smart constructors."""

    def test_k8s_health_command(self) -> None:
        """k8s_health_command should create command."""
        match k8s_health_command():
            case Success(cmd):
                assert isinstance(cmd, K8sHealthCommand)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_k8s_wait_command_default(self) -> None:
        """k8s_wait_command should create command with defaults."""
        match k8s_wait_command():
            case Success(cmd):
                assert isinstance(cmd, K8sWaitCommand)
                assert cmd.timeout == 300
                assert "metallb-system" in cmd.namespaces
            case Failure(_):
                pytest.fail("Expected Success")

    def test_k8s_wait_command_custom(self) -> None:
        """k8s_wait_command should accept custom values."""
        match k8s_wait_command(timeout=600, namespaces=["default"]):
            case Success(cmd):
                assert cmd.timeout == 600
                assert cmd.namespaces == ("default",)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_k8s_wait_command_invalid_timeout(self) -> None:
        """k8s_wait_command should reject invalid timeout."""
        match k8s_wait_command(timeout=0):
            case Success(_):
                pytest.fail("Expected Failure for invalid timeout")
            case Failure(error):
                assert "at least 1" in error

    def test_k8s_logs_command_default(self) -> None:
        """k8s_logs_command should create command with defaults."""
        match k8s_logs_command():
            case Success(cmd):
                assert isinstance(cmd, K8sLogsCommand)
                assert cmd.tail == 10
            case Failure(_):
                pytest.fail("Expected Success")

    def test_k8s_logs_command_custom(self) -> None:
        """k8s_logs_command should accept custom values."""
        match k8s_logs_command(namespaces=["kube-system"], tail=50):
            case Success(cmd):
                assert cmd.namespaces == ("kube-system",)
                assert cmd.tail == 50
            case Failure(_):
                pytest.fail("Expected Success")

    def test_k8s_logs_command_invalid_tail(self) -> None:
        """k8s_logs_command should reject invalid tail."""
        match k8s_logs_command(tail=0):
            case Success(_):
                pytest.fail("Expected Failure for invalid tail")
            case Failure(error):
                assert "at least 1" in error


class TestPulumiCommands:
    """Tests for Pulumi command smart constructors."""

    def test_pulumi_preview_command_default(self) -> None:
        """pulumi_preview_command should create command with defaults."""
        match pulumi_preview_command():
            case Success(cmd):
                assert isinstance(cmd, PulumiPreviewCommand)
                assert cmd.stack is None
                assert cmd.cwd is None
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_preview_command_custom(self) -> None:
        """pulumi_preview_command should accept custom values."""
        match pulumi_preview_command(stack="dev", cwd=Path("/infra")):
            case Success(cmd):
                assert cmd.stack == "dev"
                assert cmd.cwd == Path("/infra")
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_up_command_default(self) -> None:
        """pulumi_up_command should create command with defaults."""
        match pulumi_up_command():
            case Success(cmd):
                assert isinstance(cmd, PulumiUpCommand)
                assert cmd.yes is True
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_up_command_no_yes(self) -> None:
        """pulumi_up_command should accept yes=False."""
        match pulumi_up_command(yes=False):
            case Success(cmd):
                assert cmd.yes is False
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_destroy_command_default(self) -> None:
        """pulumi_destroy_command should create command with defaults."""
        match pulumi_destroy_command():
            case Success(cmd):
                assert isinstance(cmd, PulumiDestroyCommand)
                assert cmd.yes is False  # Destroy defaults to requiring confirmation
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_refresh_command(self) -> None:
        """pulumi_refresh_command should create command."""
        match pulumi_refresh_command(stack="prod"):
            case Success(cmd):
                assert isinstance(cmd, PulumiRefreshCommand)
                assert cmd.stack == "prod"
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_stack_init_command_valid(self) -> None:
        """pulumi_stack_init_command should accept valid stack name."""
        match pulumi_stack_init_command("my-stack"):
            case Success(cmd):
                assert isinstance(cmd, PulumiStackInitCommand)
                assert cmd.stack == "my-stack"
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_stack_init_command_with_cwd(self) -> None:
        """pulumi_stack_init_command should accept cwd."""
        match pulumi_stack_init_command("dev", cwd=Path("/infra")):
            case Success(cmd):
                assert cmd.stack == "dev"
                assert cmd.cwd == Path("/infra")
            case Failure(_):
                pytest.fail("Expected Success")

    def test_pulumi_stack_init_command_empty_name(self) -> None:
        """pulumi_stack_init_command should reject empty name."""
        match pulumi_stack_init_command(""):
            case Success(_):
                pytest.fail("Expected Failure for empty stack name")
            case Failure(error):
                assert "required" in error

    def test_pulumi_stack_init_command_whitespace_name(self) -> None:
        """pulumi_stack_init_command should reject whitespace name."""
        match pulumi_stack_init_command("   "):
            case Success(_):
                pytest.fail("Expected Failure for whitespace stack name")
            case Failure(error):
                assert "required" in error

    def test_pulumi_stack_init_command_invalid_chars(self) -> None:
        """pulumi_stack_init_command should reject invalid characters."""
        match pulumi_stack_init_command("my stack!"):
            case Success(_):
                pytest.fail("Expected Failure for invalid characters")
            case Failure(error):
                assert "Invalid stack name" in error


class TestGatewayCommands:
    """Tests for gateway command smart constructors."""

    def test_gateway_start_command_valid(self, tmp_path: Path) -> None:
        """gateway_start_command succeeds with existing config file."""
        config_file = tmp_path / "config.json"
        config_file.write_text("{}", encoding="utf-8")
        match gateway_start_command(config_path=config_file):
            case Success(cmd):
                assert isinstance(cmd, GatewayStartCommand)
                assert cmd.config_path == config_file
            case Failure(_):
                pytest.fail("Expected Success")

    def test_gateway_start_command_missing_config(self, tmp_path: Path) -> None:
        """gateway_start_command fails when config file doesn't exist."""
        missing = tmp_path / "missing.json"
        match gateway_start_command(config_path=missing):
            case Success(_):
                pytest.fail("Expected Failure for missing config")
            case Failure(error):
                assert "not found" in error

    def test_gateway_status_command_valid(self, tmp_path: Path) -> None:
        """gateway_status_command succeeds with existing config file."""
        config_file = tmp_path / "config.json"
        config_file.write_text("{}", encoding="utf-8")
        match gateway_status_command(config_path=config_file):
            case Success(cmd):
                assert isinstance(cmd, GatewayStatusCommand)
            case Failure(_):
                pytest.fail("Expected Success")

    def test_gateway_status_command_missing_config(self, tmp_path: Path) -> None:
        """gateway_status_command fails when config file doesn't exist."""
        missing = tmp_path / "missing.json"
        match gateway_status_command(config_path=missing):
            case Success(_):
                pytest.fail("Expected Failure for missing config")
            case Failure(error):
                assert "not found" in error

    def test_gateway_config_gen_command_valid(self) -> None:
        """gateway_config_gen_command succeeds with valid args."""
        match gateway_config_gen_command(output_path=Path("/tmp/test.json"), node_id="node-a"):
            case Success(cmd):
                assert isinstance(cmd, GatewayConfigGenCommand)
                assert cmd.node_id == "node-a"
                assert cmd.output_path == Path("/tmp/test.json")
            case Failure(_):
                pytest.fail("Expected Success")

    def test_gateway_config_gen_command_empty_node_id(self) -> None:
        """gateway_config_gen_command fails with empty node_id."""
        match gateway_config_gen_command(output_path=Path("/tmp/test.json"), node_id=""):
            case Success(_):
                pytest.fail("Expected Failure for empty node_id")
            case Failure(error):
                assert "required" in error


class TestUtilityFunctions:
    """Tests for utility functions."""

    def test_is_linux_on_linux(self) -> None:
        """is_linux should return True on Linux."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Linux"):
            assert is_linux() is True

    def test_is_linux_on_darwin(self) -> None:
        """is_linux should return False on Darwin."""
        with patch("prodbox.cli.command_adt.platform.system", return_value="Darwin"):
            assert is_linux() is False

    def test_requires_linux_rke2_commands(self) -> None:
        """requires_linux should return True for RKE2 commands."""
        assert requires_linux(RKE2StatusCommand()) is True
        assert requires_linux(RKE2StartCommand()) is True
        assert requires_linux(RKE2StopCommand()) is True
        assert requires_linux(RKE2RestartCommand()) is True
        assert requires_linux(RKE2EnsureCommand()) is True
        assert requires_linux(RKE2LogsCommand()) is True

    def test_requires_linux_dns_timer(self) -> None:
        """requires_linux should return True for DNS timer."""
        assert requires_linux(DNSEnsureTimerCommand()) is True

    def test_requires_linux_false_for_env(self) -> None:
        """requires_linux should return False for env commands."""
        assert requires_linux(EnvShowCommand()) is False
        assert requires_linux(EnvValidateCommand()) is False
        assert requires_linux(EnvTemplateCommand()) is False

    def test_requires_linux_false_for_host(self) -> None:
        """requires_linux should return False for host commands."""
        assert requires_linux(HostInfoCommand()) is False
        assert requires_linux(HostCheckPortsCommand()) is False
        assert requires_linux(HostEnsureToolsCommand()) is False
        assert requires_linux(HostFirewallCommand()) is False

    def test_requires_linux_false_for_dns(self) -> None:
        """requires_linux should return False for DNS check/update."""
        assert requires_linux(DNSCheckCommand()) is False
        assert requires_linux(DNSUpdateCommand()) is False

    def test_requires_linux_false_for_k8s(self) -> None:
        """requires_linux should return False for K8s commands."""
        assert requires_linux(K8sHealthCommand()) is False
        assert requires_linux(K8sWaitCommand()) is False
        assert requires_linux(K8sLogsCommand()) is False

    def test_requires_linux_false_for_pulumi(self) -> None:
        """requires_linux should return False for Pulumi commands."""
        assert requires_linux(PulumiPreviewCommand()) is False
        assert requires_linux(PulumiUpCommand()) is False
        assert requires_linux(PulumiDestroyCommand()) is False
        assert requires_linux(PulumiRefreshCommand()) is False
        assert requires_linux(PulumiStackInitCommand(stack="test")) is False

    def test_requires_settings_dns_commands(self) -> None:
        """requires_settings should return True for DNS commands."""
        assert requires_settings(DNSCheckCommand()) is True
        assert requires_settings(DNSUpdateCommand()) is True
        assert requires_settings(DNSEnsureTimerCommand()) is True

    def test_requires_settings_k8s_commands(self) -> None:
        """requires_settings should return True for K8s commands."""
        assert requires_settings(K8sHealthCommand()) is True
        assert requires_settings(K8sWaitCommand()) is True
        assert requires_settings(K8sLogsCommand()) is True

    def test_requires_settings_pulumi_commands(self) -> None:
        """requires_settings should return True for Pulumi commands."""
        assert requires_settings(PulumiPreviewCommand()) is True
        assert requires_settings(PulumiUpCommand()) is True
        assert requires_settings(PulumiDestroyCommand()) is True
        assert requires_settings(PulumiRefreshCommand()) is True
        assert requires_settings(PulumiStackInitCommand(stack="test")) is True

    def test_requires_settings_env_show_validate(self) -> None:
        """requires_settings should return True for env show/validate."""
        assert requires_settings(EnvShowCommand()) is True
        assert requires_settings(EnvValidateCommand()) is True

    def test_requires_settings_env_template(self) -> None:
        """requires_settings should return False for env template."""
        assert requires_settings(EnvTemplateCommand()) is False

    def test_requires_settings_host_commands(self) -> None:
        """requires_settings should return False for host commands."""
        assert requires_settings(HostInfoCommand()) is False
        assert requires_settings(HostCheckPortsCommand()) is False
        assert requires_settings(HostEnsureToolsCommand()) is False
        assert requires_settings(HostFirewallCommand()) is False

    def test_requires_settings_rke2_commands(self) -> None:
        """requires_settings should return False for RKE2 commands."""
        assert requires_settings(RKE2StatusCommand()) is False
        assert requires_settings(RKE2StartCommand()) is False
        assert requires_settings(RKE2StopCommand()) is False
        assert requires_settings(RKE2RestartCommand()) is False
        assert requires_settings(RKE2EnsureCommand()) is False
        assert requires_settings(RKE2LogsCommand()) is False

    def test_requires_linux_false_for_gateway(self) -> None:
        """requires_linux should return False for gateway commands."""
        assert requires_linux(GatewayStartCommand(config_path=Path("/tmp/c.json"))) is False
        assert requires_linux(GatewayStatusCommand(config_path=Path("/tmp/c.json"))) is False
        assert (
            requires_linux(GatewayConfigGenCommand(output_path=Path("/tmp/o.json"), node_id="n"))
            is False
        )

    def test_requires_settings_false_for_gateway(self) -> None:
        """requires_settings should return False for gateway commands."""
        assert requires_settings(GatewayStartCommand(config_path=Path("/tmp/c.json"))) is False
        assert requires_settings(GatewayStatusCommand(config_path=Path("/tmp/c.json"))) is False
        assert (
            requires_settings(GatewayConfigGenCommand(output_path=Path("/tmp/o.json"), node_id="n"))
            is False
        )
