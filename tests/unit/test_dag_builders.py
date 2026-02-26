"""Unit tests for DAG builders module.

These tests verify:
1. Each command type produces a valid DAG
2. Root effect_id matches expected pattern
3. Prerequisites are correctly specified
4. All prerequisites exist in the registry

Note: These are pure function tests - no mocks needed.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from prodbox.cli.command_adt import (
    DNSCheckCommand,
    DNSEnsureTimerCommand,
    DNSUpdateCommand,
    EnvShowCommand,
    EnvTemplateCommand,
    EnvValidateCommand,
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
)
from prodbox.cli.dag_builders import command_to_dag
from prodbox.cli.effects import (
    CaptureKubectlOutput,
    CaptureSubprocessOutput,
    CheckFileExists,
    CheckServiceStatus,
    FetchPublicIP,
    GetJournalLogs,
    KubectlWait,
    PulumiDestroy,
    PulumiPreview,
    PulumiRefresh,
    PulumiUp,
    Pure,
    RunKubectlCommand,
    RunPulumiCommand,
    RunSystemdCommand,
    ValidateSettings,
    ValidateTool,
)
from prodbox.cli.prerequisite_registry import PREREQUISITE_REGISTRY
from prodbox.cli.types import Failure, Success


class TestEnvCommandDAGBuilders:
    """Tests for environment command DAG builders."""

    def test_env_show_dag(self) -> None:
        """command_to_dag should build DAG for EnvShowCommand."""
        cmd = EnvShowCommand(show_secrets=False)

        match command_to_dag(cmd):
            case Success(dag):
                assert "env_show" in dag
                assert len(dag) > 0
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_env_validate_dag(self) -> None:
        """command_to_dag should build DAG for EnvValidateCommand."""
        cmd = EnvValidateCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "env_validate" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_env_template_dag(self) -> None:
        """command_to_dag should build DAG for EnvTemplateCommand."""
        cmd = EnvTemplateCommand(output_path=Path(".env.template"))

        match command_to_dag(cmd):
            case Success(dag):
                assert "env_template" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestHostCommandDAGBuilders:
    """Tests for host command DAG builders."""

    def test_host_info_dag(self) -> None:
        """command_to_dag should build DAG for HostInfoCommand."""
        cmd = HostInfoCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "host_info" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_check_ports_dag(self) -> None:
        """command_to_dag should build DAG for HostCheckPortsCommand."""
        cmd = HostCheckPortsCommand(ports=(80, 443))

        match command_to_dag(cmd):
            case Success(dag):
                assert "host_check_ports" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_ensure_tools_dag(self) -> None:
        """command_to_dag should build DAG for HostEnsureToolsCommand."""
        cmd = HostEnsureToolsCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "host_ensure_tools" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_firewall_dag(self) -> None:
        """command_to_dag should build DAG for HostFirewallCommand."""
        cmd = HostFirewallCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "host_firewall" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestRKE2CommandDAGBuilders:
    """Tests for RKE2 command DAG builders."""

    def test_rke2_status_dag(self) -> None:
        """command_to_dag should build DAG for RKE2StatusCommand."""
        cmd = RKE2StatusCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_status" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_start_dag(self) -> None:
        """command_to_dag should build DAG for RKE2StartCommand."""
        cmd = RKE2StartCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_start" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_stop_dag(self) -> None:
        """command_to_dag should build DAG for RKE2StopCommand."""
        cmd = RKE2StopCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_stop" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_restart_dag(self) -> None:
        """command_to_dag should build DAG for RKE2RestartCommand."""
        cmd = RKE2RestartCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_restart" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_ensure_dag(self) -> None:
        """command_to_dag should build DAG for RKE2EnsureCommand."""
        cmd = RKE2EnsureCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_ensure" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_logs_dag(self) -> None:
        """command_to_dag should build DAG for RKE2LogsCommand."""
        cmd = RKE2LogsCommand(lines=100)

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_logs" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestDNSCommandDAGBuilders:
    """Tests for DNS command DAG builders."""

    def test_dns_check_dag(self) -> None:
        """command_to_dag should build DAG for DNSCheckCommand."""
        cmd = DNSCheckCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "dns_check" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_dns_update_dag(self) -> None:
        """command_to_dag should build DAG for DNSUpdateCommand."""
        cmd = DNSUpdateCommand(force=True)

        match command_to_dag(cmd):
            case Success(dag):
                assert "dns_update" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestK8sCommandDAGBuilders:
    """Tests for Kubernetes command DAG builders."""

    def test_k8s_health_dag(self) -> None:
        """command_to_dag should build DAG for K8sHealthCommand."""
        cmd = K8sHealthCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "k8s_health" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_k8s_wait_dag(self) -> None:
        """command_to_dag should build DAG for K8sWaitCommand."""
        cmd = K8sWaitCommand(timeout=300, namespaces=("default",))

        match command_to_dag(cmd):
            case Success(dag):
                assert "k8s_wait" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_k8s_logs_dag(self) -> None:
        """command_to_dag should build DAG for K8sLogsCommand."""
        cmd = K8sLogsCommand(namespaces=("kube-system",), tail=50)

        match command_to_dag(cmd):
            case Success(dag):
                assert "k8s_logs" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestPulumiCommandDAGBuilders:
    """Tests for Pulumi command DAG builders."""

    def test_pulumi_preview_dag(self) -> None:
        """command_to_dag should build DAG for PulumiPreviewCommand."""
        cmd = PulumiPreviewCommand(stack="dev")

        match command_to_dag(cmd):
            case Success(dag):
                assert "pulumi_preview" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_up_dag(self) -> None:
        """command_to_dag should build DAG for PulumiUpCommand."""
        cmd = PulumiUpCommand(stack="dev", yes=True)

        match command_to_dag(cmd):
            case Success(dag):
                assert "pulumi_up" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_destroy_dag(self) -> None:
        """command_to_dag should build DAG for PulumiDestroyCommand."""
        cmd = PulumiDestroyCommand(stack="dev", yes=True)

        match command_to_dag(cmd):
            case Success(dag):
                assert "pulumi_destroy" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_refresh_dag(self) -> None:
        """command_to_dag should build DAG for PulumiRefreshCommand."""
        cmd = PulumiRefreshCommand(stack="dev")

        match command_to_dag(cmd):
            case Success(dag):
                assert "pulumi_refresh" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_stack_init_dag(self) -> None:
        """command_to_dag should build DAG for PulumiStackInitCommand."""
        cmd = PulumiStackInitCommand(stack="new-stack")

        match command_to_dag(cmd):
            case Success(dag):
                assert "pulumi_stack_init" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


# =============================================================================
# Phase 2: Prerequisite Verification Tests
# =============================================================================


class TestEnvCommandPrerequisites:
    """Verify prerequisites for environment commands."""

    def test_env_show_requires_settings(self) -> None:
        """EnvShowCommand should require settings_loaded prerequisite."""
        cmd = EnvShowCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("env_show")
                assert root is not None
                assert "settings_loaded" in root.prerequisites
                assert isinstance(root.effect, ValidateSettings)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_env_validate_requires_settings(self) -> None:
        """EnvValidateCommand should require settings_loaded prerequisite."""
        cmd = EnvValidateCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("env_validate")
                assert root is not None
                assert "settings_loaded" in root.prerequisites
                assert isinstance(root.effect, ValidateSettings)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_env_template_no_prerequisites(self) -> None:
        """EnvTemplateCommand should have no prerequisites."""
        cmd = EnvTemplateCommand(output_path=Path(".env.template"))
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("env_template")
                assert root is not None
                assert root.prerequisites == frozenset()
                assert isinstance(root.effect, Pure)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestHostCommandPrerequisites:
    """Verify prerequisites for host commands."""

    def test_host_info_no_prerequisites(self) -> None:
        """HostInfoCommand should have no prerequisites."""
        cmd = HostInfoCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_info")
                assert root is not None
                assert root.prerequisites == frozenset()
                assert isinstance(root.effect, CaptureSubprocessOutput)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_check_ports_no_prerequisites(self) -> None:
        """HostCheckPortsCommand should have no prerequisites."""
        cmd = HostCheckPortsCommand(ports=(80, 443))
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_check_ports")
                assert root is not None
                assert root.prerequisites == frozenset()
                assert isinstance(root.effect, Pure)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_ensure_tools_requires_tools(self) -> None:
        """HostEnsureToolsCommand should require tool prerequisites."""
        cmd = HostEnsureToolsCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_ensure_tools")
                assert root is not None
                assert "tool_kubectl" in root.prerequisites
                assert "tool_helm" in root.prerequisites
                assert "tool_pulumi" in root.prerequisites
                assert isinstance(root.effect, ValidateTool)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_firewall_no_prerequisites(self) -> None:
        """HostFirewallCommand should have no prerequisites."""
        cmd = HostFirewallCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_firewall")
                assert root is not None
                assert root.prerequisites == frozenset()
                assert isinstance(root.effect, CaptureSubprocessOutput)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestRKE2CommandPrerequisites:
    """Verify prerequisites for RKE2 commands."""

    def test_rke2_status_requires_linux_and_rke2(self) -> None:
        """RKE2StatusCommand should require platform_linux and rke2_installed."""
        cmd = RKE2StatusCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_status")
                assert root is not None
                assert "platform_linux" in root.prerequisites
                assert "rke2_installed" in root.prerequisites
                assert isinstance(root.effect, CheckServiceStatus)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_start_requires_service_exists(self) -> None:
        """RKE2StartCommand should require rke2_service_exists."""
        cmd = RKE2StartCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_start")
                assert root is not None
                assert "rke2_service_exists" in root.prerequisites
                assert isinstance(root.effect, RunSystemdCommand)
                assert root.effect.action == "start"
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_stop_requires_service_exists(self) -> None:
        """RKE2StopCommand should require rke2_service_exists."""
        cmd = RKE2StopCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_stop")
                assert root is not None
                assert "rke2_service_exists" in root.prerequisites
                assert isinstance(root.effect, RunSystemdCommand)
                assert root.effect.action == "stop"
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_restart_requires_service_exists(self) -> None:
        """RKE2RestartCommand should require rke2_service_exists."""
        cmd = RKE2RestartCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_restart")
                assert root is not None
                assert "rke2_service_exists" in root.prerequisites
                assert isinstance(root.effect, RunSystemdCommand)
                assert root.effect.action == "restart"
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_ensure_requires_linux(self) -> None:
        """RKE2EnsureCommand should require platform_linux."""
        cmd = RKE2EnsureCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_ensure")
                assert root is not None
                assert "platform_linux" in root.prerequisites
                assert isinstance(root.effect, CheckFileExists)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_logs_requires_service_exists(self) -> None:
        """RKE2LogsCommand should require rke2_service_exists."""
        cmd = RKE2LogsCommand(lines=100)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_logs")
                assert root is not None
                assert "rke2_service_exists" in root.prerequisites
                assert isinstance(root.effect, GetJournalLogs)
                assert root.effect.lines == 100
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestDNSCommandPrerequisites:
    """Verify prerequisites for DNS commands."""

    def test_dns_check_requires_settings_and_aws(self) -> None:
        """DNSCheckCommand should require settings and AWS credentials."""
        cmd = DNSCheckCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("dns_check")
                assert root is not None
                assert "settings_loaded" in root.prerequisites
                assert "aws_credentials_valid" in root.prerequisites
                assert isinstance(root.effect, FetchPublicIP)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_dns_update_requires_settings_and_route53(self) -> None:
        """DNSUpdateCommand should require settings and route53 access."""
        cmd = DNSUpdateCommand(force=True)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("dns_update")
                assert root is not None
                assert "settings_loaded" in root.prerequisites
                assert "route53_accessible" in root.prerequisites
                assert isinstance(root.effect, FetchPublicIP)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_dns_ensure_timer_requires_settings_and_systemd(self) -> None:
        """DNSEnsureTimerCommand should require settings and systemd."""
        cmd = DNSEnsureTimerCommand(interval=10)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("dns_ensure_timer")
                assert root is not None
                assert "settings_loaded" in root.prerequisites
                assert "systemd_available" in root.prerequisites
                assert isinstance(root.effect, RunSystemdCommand)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestK8sCommandPrerequisites:
    """Verify prerequisites for Kubernetes commands."""

    def test_k8s_health_requires_cluster_reachable(self) -> None:
        """K8sHealthCommand should require k8s_cluster_reachable."""
        cmd = K8sHealthCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("k8s_health")
                assert root is not None
                assert "k8s_cluster_reachable" in root.prerequisites
                assert isinstance(root.effect, CaptureKubectlOutput)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_k8s_wait_requires_cluster_reachable(self) -> None:
        """K8sWaitCommand should require k8s_cluster_reachable."""
        cmd = K8sWaitCommand(timeout=300)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("k8s_wait")
                assert root is not None
                assert "k8s_cluster_reachable" in root.prerequisites
                assert isinstance(root.effect, KubectlWait)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_k8s_logs_requires_cluster_reachable(self) -> None:
        """K8sLogsCommand should require k8s_cluster_reachable."""
        cmd = K8sLogsCommand(tail=50)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("k8s_logs")
                assert root is not None
                assert "k8s_cluster_reachable" in root.prerequisites
                assert isinstance(root.effect, RunKubectlCommand)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestPulumiCommandPrerequisites:
    """Verify prerequisites for Pulumi commands."""

    def test_pulumi_preview_requires_pulumi_tools(self) -> None:
        """PulumiPreviewCommand should require tool_pulumi and pulumi_logged_in."""
        cmd = PulumiPreviewCommand(stack="dev")
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_preview")
                assert root is not None
                assert "tool_pulumi" in root.prerequisites
                assert "pulumi_logged_in" in root.prerequisites
                assert isinstance(root.effect, PulumiPreview)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_up_requires_stack_exists(self) -> None:
        """PulumiUpCommand should require pulumi_stack_exists."""
        cmd = PulumiUpCommand(stack="dev", yes=True)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_up")
                assert root is not None
                assert "tool_pulumi" in root.prerequisites
                assert "pulumi_stack_exists" in root.prerequisites
                assert isinstance(root.effect, PulumiUp)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_destroy_requires_stack_exists(self) -> None:
        """PulumiDestroyCommand should require pulumi_stack_exists."""
        cmd = PulumiDestroyCommand(stack="dev", yes=True)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_destroy")
                assert root is not None
                assert "tool_pulumi" in root.prerequisites
                assert "pulumi_stack_exists" in root.prerequisites
                assert isinstance(root.effect, PulumiDestroy)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_refresh_requires_stack_exists(self) -> None:
        """PulumiRefreshCommand should require pulumi_stack_exists."""
        cmd = PulumiRefreshCommand(stack="dev")
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_refresh")
                assert root is not None
                assert "tool_pulumi" in root.prerequisites
                assert "pulumi_stack_exists" in root.prerequisites
                assert isinstance(root.effect, PulumiRefresh)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_stack_init_requires_logged_in(self) -> None:
        """PulumiStackInitCommand should require pulumi_logged_in."""
        cmd = PulumiStackInitCommand(stack="new-stack")
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_stack_init")
                assert root is not None
                assert "tool_pulumi" in root.prerequisites
                assert "pulumi_logged_in" in root.prerequisites
                assert isinstance(root.effect, RunPulumiCommand)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestAllPrerequisitesExistInRegistry:
    """Verify all referenced prerequisites exist in the registry."""

    def test_all_env_prerequisites_exist(self) -> None:
        """All prerequisites referenced by env commands should exist."""
        commands = [
            EnvShowCommand(),
            EnvValidateCommand(),
            EnvTemplateCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert prereq_id in PREREQUISITE_REGISTRY, (
                                f"Prerequisite '{prereq_id}' not in registry "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")

    def test_all_host_prerequisites_exist(self) -> None:
        """All prerequisites referenced by host commands should exist."""
        commands = [
            HostInfoCommand(),
            HostCheckPortsCommand(),
            HostEnsureToolsCommand(),
            HostFirewallCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert prereq_id in PREREQUISITE_REGISTRY, (
                                f"Prerequisite '{prereq_id}' not in registry "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")

    def test_all_rke2_prerequisites_exist(self) -> None:
        """All prerequisites referenced by RKE2 commands should exist."""
        commands = [
            RKE2StatusCommand(),
            RKE2StartCommand(),
            RKE2StopCommand(),
            RKE2RestartCommand(),
            RKE2EnsureCommand(),
            RKE2LogsCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert prereq_id in PREREQUISITE_REGISTRY, (
                                f"Prerequisite '{prereq_id}' not in registry "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")

    def test_all_dns_prerequisites_exist(self) -> None:
        """All prerequisites referenced by DNS commands should exist."""
        commands = [
            DNSCheckCommand(),
            DNSUpdateCommand(),
            DNSEnsureTimerCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert prereq_id in PREREQUISITE_REGISTRY, (
                                f"Prerequisite '{prereq_id}' not in registry "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")

    def test_all_k8s_prerequisites_exist(self) -> None:
        """All prerequisites referenced by K8s commands should exist."""
        commands = [
            K8sHealthCommand(),
            K8sWaitCommand(),
            K8sLogsCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert prereq_id in PREREQUISITE_REGISTRY, (
                                f"Prerequisite '{prereq_id}' not in registry "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")

    def test_all_pulumi_prerequisites_exist(self) -> None:
        """All prerequisites referenced by Pulumi commands should exist."""
        commands = [
            PulumiPreviewCommand(),
            PulumiUpCommand(),
            PulumiDestroyCommand(),
            PulumiRefreshCommand(),
            PulumiStackInitCommand(stack="test"),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert prereq_id in PREREQUISITE_REGISTRY, (
                                f"Prerequisite '{prereq_id}' not in registry "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")
