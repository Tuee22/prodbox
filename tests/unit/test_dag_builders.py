"""Unit tests for DAG builders module.

These tests verify:
1. Each command type produces a valid DAG
2. Root effect_id matches expected pattern
3. Prerequisites are correctly specified
4. All prerequisites exist in the registry

Note: These are pure function tests - no mocks needed.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from prodbox.cli.command_adt import (
    DNSCheckCommand,
    GatewayConfigGenCommand,
    GatewayStartCommand,
    GatewayStatusCommand,
    HostCheckPortsCommand,
    HostEnsureToolsCommand,
    HostFirewallCommand,
    HostInfoCommand,
    HostPublicEdgeCommand,
    K8sHealthCommand,
    K8sLogsCommand,
    K8sWaitCommand,
    PulumiDestroyCommand,
    PulumiPreviewCommand,
    PulumiRefreshCommand,
    PulumiStackInitCommand,
    PulumiUpCommand,
    RKE2DeleteCommand,
    RKE2InstallCommand,
    RKE2LogsCommand,
    RKE2RestartCommand,
    RKE2StartCommand,
    RKE2StatusCommand,
    RKE2StopCommand,
)
from prodbox.cli.dag_builders import command_to_dag
from prodbox.cli.effect_dag import PrerequisiteFailurePolicy
from prodbox.cli.effects import (
    AnnotateProdboxManagedResources,
    CaptureKubectlOutput,
    CaptureSubprocessOutput,
    CheckPortAvailability,
    CheckServiceStatus,
    Custom,
    EnsureHarborRegistry,
    EnsureMinio,
    EnsureProdboxIdentityConfigMap,
    EnsureRetainedLocalStorage,
    EnsureRke2IngressController,
    GenerateGatewayConfig,
    GetJournalLogs,
    MachineIdentity,
    Parallel,
    PulumiDestroy,
    PulumiPreview,
    PulumiRefresh,
    PulumiStackSelect,
    Pure,
    QueryGatewayState,
    QueryRoute53Record,
    RunPulumiCommand,
    RunSystemdCommand,
    Sequence,
    ValidateTool,
    WriteStdout,
)
from prodbox.cli.types import Failure, Success


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

    def test_host_public_edge_dag(self) -> None:
        """command_to_dag should build DAG for HostPublicEdgeCommand."""
        cmd = HostPublicEdgeCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "host_public_edge" in dag
                assert "host_public_edge_public_ip" in dag
                assert "host_public_edge_route53_record" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestGatewayCommandDAGBuilders:
    """Tests for gateway command DAG builders."""

    def test_gateway_start_dag(self) -> None:
        """command_to_dag should build DAG for GatewayStartCommand."""
        cmd = GatewayStartCommand(config_path=Path("/tmp/gateway.json"))

        match command_to_dag(cmd):
            case Success(dag):
                assert "start_gateway_daemon" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_gateway_status_dag(self) -> None:
        """command_to_dag should build DAG for GatewayStatusCommand."""
        cmd = GatewayStatusCommand(config_path=Path("/tmp/gateway.json"))

        match command_to_dag(cmd):
            case Success(dag):
                assert "gateway_status" in dag
                assert "query_gateway_state" in dag
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_gateway_config_gen_dag(self) -> None:
        """command_to_dag should build DAG for GatewayConfigGenCommand."""
        cmd = GatewayConfigGenCommand(
            output_path=Path("/tmp/gateway.json"),
            node_id="node-a",
        )

        match command_to_dag(cmd):
            case Success(dag):
                assert "generate_gateway_config" in dag
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

    def test_rke2_install_dag(self) -> None:
        """command_to_dag should build DAG for RKE2InstallCommand."""
        cmd = RKE2InstallCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_install" in dag
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

    def test_rke2_delete_dag(self) -> None:
        """command_to_dag should build DAG for RKE2DeleteCommand."""
        cmd = RKE2DeleteCommand()

        match command_to_dag(cmd):
            case Success(dag):
                assert "rke2_delete" in dag
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
        """HostCheckPortsCommand should depend only on its local probe node."""
        cmd = HostCheckPortsCommand(ports=(80, 443))
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_check_ports")
                assert root is not None
                assert root.prerequisites == frozenset({"host_check_ports_probe"})
                assert isinstance(root.effect, WriteStdout)
                probe = dag.get_node("host_check_ports_probe")
                assert probe is not None
                assert probe.prerequisites == frozenset()
                assert isinstance(probe.effect, CheckPortAvailability)
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
                assert "tool_docker" in root.prerequisites
                assert "tool_ctr" in root.prerequisites
                assert "tool_sudo" in root.prerequisites
                assert "tool_systemctl" in root.prerequisites
                assert "tool_rke2" in root.prerequisites
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

    def test_host_public_edge_requires_settings_route53_and_k8s(self) -> None:
        """HostPublicEdgeCommand should gather settings, Route53, and cluster diagnostics."""
        cmd = HostPublicEdgeCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_public_edge")
                assert root is not None
                assert "settings_object" in root.prerequisites
                assert "host_public_edge_public_ip" in root.prerequisites
                assert "host_public_edge_route53_record" in root.prerequisites
                assert "host_public_edge_vscode_certificate" in root.prerequisites
                assert root.prerequisite_failure_policy == PrerequisiteFailurePolicy.IGNORE
                assert isinstance(root.effect, WriteStdout)

                route53 = dag.get_node("host_public_edge_route53_record")
                assert route53 is not None
                assert route53.prerequisites == frozenset(["settings_object", "route53_accessible"])
                built = route53.build_effect(
                    None,
                    {
                        "settings_object": Success(
                            {
                                "route53_zone_id": "Z123",
                                "vscode_fqdn": "code.example.com",
                                "demo_fqdn": "demo.example.com",
                                "aws_region": "us-east-1",
                            }
                        )
                    },
                )
                assert isinstance(built, QueryRoute53Record)
                assert built.zone_id == "Z123"
                assert built.fqdn == "code.example.com"
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_public_edge_effect_builder_renders_ready_report(self) -> None:
        """Host public-edge root should render the canonical readiness report."""
        cmd = HostPublicEdgeCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_public_edge")
                assert root is not None
                built = root.build_effect(
                    None,
                    {
                        "settings_object": Success(
                            {
                                "demo_fqdn": "demo.example.com",
                                "vscode_fqdn": "code.example.com",
                                "route53_zone_id": "Z123",
                                "aws_region": "us-east-1",
                                "active_lan_interface": "eno1",
                                "active_lan_ipv4": "192.168.1.20",
                                "active_lan_network_cidr": "192.168.1.0/24",
                            }
                        ),
                        "host_public_edge_public_ip": Success("203.0.113.10"),
                        "host_public_edge_route53_record": Success("203.0.113.10"),
                        "host_public_edge_ingress_classes": Success(
                            (
                                0,
                                json.dumps({"items": [{"metadata": {"name": "traefik"}}]}),
                                "",
                            )
                        ),
                        "host_public_edge_traefik_service": Success(
                            (
                                0,
                                json.dumps(
                                    {
                                        "items": [
                                            {
                                                "status": {
                                                    "loadBalancer": {
                                                        "ingress": [{"ip": "192.168.1.240"}]
                                                    }
                                                }
                                            }
                                        ]
                                    }
                                ),
                                "",
                            )
                        ),
                        "host_public_edge_ingress_nginx_services": Success(
                            (0, json.dumps({"items": []}), "")
                        ),
                        "host_public_edge_vscode_ingress": Success(
                            (
                                0,
                                json.dumps(
                                    {
                                        "spec": {
                                            "ingressClassName": "traefik",
                                            "rules": [{"host": "code.example.com"}],
                                        }
                                    }
                                ),
                                "",
                            )
                        ),
                        "host_public_edge_vscode_certificate": Success(
                            (
                                0,
                                json.dumps(
                                    {
                                        "status": {
                                            "conditions": [
                                                {"type": "Ready", "status": "True"},
                                            ]
                                        }
                                    }
                                ),
                                "",
                            )
                        ),
                    },
                )
                assert isinstance(built, WriteStdout)
                assert "CLASSIFICATION=ready-for-external-proof" in built.text
                assert "ROUTE53_STATUS=in-sync" in built.text
                assert "ACTIVE_LAN_INTERFACE=eno1" in built.text
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_host_public_edge_effect_builder_renders_report_when_optional_edge_state_is_absent(
        self,
    ) -> None:
        """Host public-edge should render a report when optional edge objects or APIs are absent."""
        cmd = HostPublicEdgeCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("host_public_edge")
                assert root is not None
                built = root.build_effect(
                    None,
                    {
                        "settings_object": Success(
                            {
                                "demo_fqdn": "demo.example.com",
                                "vscode_fqdn": "code.example.com",
                                "route53_zone_id": "Z123",
                                "aws_region": "us-east-1",
                                "active_lan_interface": "eno1",
                                "active_lan_ipv4": "192.168.1.20",
                                "active_lan_network_cidr": "192.168.1.0/24",
                            }
                        ),
                        "host_public_edge_public_ip": Success("203.0.113.10"),
                        "host_public_edge_route53_record": Success("203.0.113.10"),
                        "host_public_edge_ingress_classes": Success(
                            (0, json.dumps({"items": []}), "")
                        ),
                        "host_public_edge_traefik_service": Failure(
                            'kubectl failed: Error from server (NotFound): namespaces "traefik-system" not found'
                        ),
                        "host_public_edge_ingress_nginx_services": Success(
                            (0, json.dumps({"items": []}), "")
                        ),
                        "host_public_edge_vscode_ingress": Failure(
                            'kubectl failed: Error from server (NotFound): namespaces "vscode" not found'
                        ),
                        "host_public_edge_vscode_certificate": Failure(
                            'kubectl failed: error: the server doesn\'t have a resource type "certificate"'
                        ),
                    },
                )
                assert isinstance(built, WriteStdout)
                assert "TRAEFIK_SERVICE_IP=<missing>" in built.text
                assert "VSCODE_INGRESS_CLASS=<missing>" in built.text
                assert "CERTIFICATE_READY=missing" in built.text
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

    def test_rke2_install_requires_supported_host_tools_and_settings(self) -> None:
        """RKE2InstallCommand should gate on the supported host, tools, and settings."""
        cmd = RKE2InstallCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_install")
                assert root is not None
                assert "supported_ubuntu_2404" in root.prerequisites
                assert "systemd_available" in root.prerequisites
                assert "tool_kubectl" in root.prerequisites
                assert "tool_helm" in root.prerequisites
                assert "tool_docker" in root.prerequisites
                assert "tool_ctr" in root.prerequisites
                assert "tool_sudo" in root.prerequisites
                assert "tool_systemctl" in root.prerequisites
                assert "machine_identity" in root.prerequisites
                assert "settings_object" in root.prerequisites
                assert isinstance(root.effect, Sequence)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_delete_requires_supported_host_and_settings(self) -> None:
        """RKE2DeleteCommand should require the supported host, sudo, and settings."""
        cmd = RKE2DeleteCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_delete")
                assert root is not None
                assert "supported_ubuntu_2404" in root.prerequisites
                assert "systemd_available" in root.prerequisites
                assert "tool_sudo" in root.prerequisites
                assert "tool_systemctl" in root.prerequisites
                assert "settings_object" in root.prerequisites
                assert isinstance(root.effect, Sequence)
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

    def test_rke2_install_effect_builder_uses_machine_identity_and_settings(self) -> None:
        """rke2 install should build the host-owned install/reconcile sequence."""
        cmd = RKE2InstallCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_install")
                assert root is not None
                prereq_results = {
                    "machine_identity": Success(
                        MachineIdentity(
                            machine_id="0123456789abcdef0123456789abcdef",
                            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
                        )
                    ),
                    "settings_object": Success({"manual_pv_host_root": Path("/tmp/manual-pv")}),
                }
                built_effect = root.build_effect(None, prereq_results)
                assert isinstance(built_effect, Sequence)
                assert len(built_effect.effects) == 11
                assert isinstance(built_effect.effects[0], Custom)
                assert isinstance(built_effect.effects[1], EnsureRke2IngressController)
                assert isinstance(built_effect.effects[8], EnsureProdboxIdentityConfigMap)
                assert isinstance(built_effect.effects[9], Parallel)
                assert isinstance(built_effect.effects[10], AnnotateProdboxManagedResources)
                parallel_effect = built_effect.effects[9]
                assert len(parallel_effect.effects) == 2
                assert isinstance(parallel_effect.effects[0], EnsureHarborRegistry)
                assert isinstance(parallel_effect.effects[1], Sequence)
                storage_minio_effect = parallel_effect.effects[1]
                assert len(storage_minio_effect.effects) == 2
                assert isinstance(storage_minio_effect.effects[0], EnsureRetainedLocalStorage)
                assert storage_minio_effect.effects[0].host_storage_base_path == Path(
                    "/tmp/manual-pv"
                )
                assert isinstance(storage_minio_effect.effects[1], EnsureMinio)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_rke2_delete_effect_builder_uses_settings(self) -> None:
        """rke2 delete should build the destructive delete sequence from settings."""
        cmd = RKE2DeleteCommand()
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("rke2_delete")
                assert root is not None
                prereq_results = {
                    "settings_object": Success({"manual_pv_host_root": Path("/tmp/manual-pv")}),
                }
                built_effect = root.build_effect(None, prereq_results)
                assert isinstance(built_effect, Sequence)
                assert len(built_effect.effects) == 2
                assert isinstance(built_effect.effects[0], Custom)
                assert isinstance(built_effect.effects[1], WriteStdout)
                assert "/tmp/manual-pv" in built_effect.effects[1].text
                assert ".prodbox-state" in built_effect.effects[1].text
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
                assert "settings_object" in root.prerequisites
                assert "dns_public_ip" in root.prerequisites
                assert "dns_current_record" in root.prerequisites
                assert isinstance(root.effect, WriteStdout)
                current_record_node = dag.get_node("dns_current_record")
                assert current_record_node is not None
                assert "route53_accessible" in current_record_node.prerequisites
                assert isinstance(current_record_node.effect, QueryRoute53Record)
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
                assert isinstance(root.effect, Sequence)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_k8s_logs_requires_cluster_reachable(self) -> None:
        """K8sLogsCommand should require k8s_cluster_reachable."""
        cmd = K8sLogsCommand(tail=50)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("k8s_logs")
                assert root is not None
                assert isinstance(root.effect, WriteStdout)
                pod_list = dag.get_node("k8s_logs_pod_list_metallb_system")
                assert pod_list is not None
                assert "k8s_cluster_reachable" in pod_list.prerequisites
                assert isinstance(pod_list.effect, CaptureKubectlOutput)
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
                assert "pulumi_preview_stack_select" in root.prerequisites
                assert "machine_identity" in root.prerequisites
                assert "settings_object" in root.prerequisites
                assert isinstance(root.effect, PulumiPreview)
                stack_select = dag.get_node("pulumi_preview_stack_select")
                assert stack_select is not None
                assert "pulumi_logged_in" in stack_select.prerequisites
                assert isinstance(stack_select.effect, PulumiStackSelect)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_up_bootstraps_missing_stack(self) -> None:
        """PulumiUpCommand should auto-create the selected stack when needed."""
        cmd = PulumiUpCommand(stack="dev", yes=True)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_up")
                assert root is not None
                assert "pulumi_up_stack_select" in root.prerequisites
                assert "machine_identity" in root.prerequisites
                assert "k8s_cluster_reachable" in root.prerequisites
                assert "settings_object" in root.prerequisites
                assert isinstance(root.effect, Sequence)
                stack_select = dag.get_node("pulumi_up_stack_select")
                assert stack_select is not None
                assert isinstance(stack_select.effect, PulumiStackSelect)
                assert stack_select.effect.create_if_missing is True
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_destroy_requires_stack_exists(self) -> None:
        """PulumiDestroyCommand should require explicit stack selection."""
        cmd = PulumiDestroyCommand(stack="dev", yes=True)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_destroy")
                assert root is not None
                assert "pulumi_destroy_stack_select" in root.prerequisites
                assert "machine_identity" in root.prerequisites
                assert "settings_object" in root.prerequisites
                assert isinstance(root.effect, PulumiDestroy)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_refresh_bootstraps_missing_stack(self) -> None:
        """PulumiRefreshCommand should auto-create the selected stack when needed."""
        cmd = PulumiRefreshCommand(stack="dev")
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_refresh")
                assert root is not None
                assert "pulumi_refresh_stack_select" in root.prerequisites
                assert "machine_identity" in root.prerequisites
                assert "settings_object" in root.prerequisites
                assert isinstance(root.effect, PulumiRefresh)
                stack_select = dag.get_node("pulumi_refresh_stack_select")
                assert stack_select is not None
                assert isinstance(stack_select.effect, PulumiStackSelect)
                assert stack_select.effect.create_if_missing is True
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_pulumi_up_effect_builder_adds_annotation_reconciliation(self) -> None:
        """pulumi up should apply identity configmap and annotation reconciliation after apply."""
        cmd = PulumiUpCommand(stack="dev", yes=True)
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("pulumi_up")
                assert root is not None
                prereq_results = {
                    "settings_object": Success(object()),
                    "machine_identity": Success(
                        MachineIdentity(
                            machine_id="0123456789abcdef0123456789abcdef",
                            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
                        )
                    ),
                }
                built_effect = root.build_effect(None, prereq_results)
                assert isinstance(built_effect, Sequence)
                assert len(built_effect.effects) == 3
                assert isinstance(built_effect.effects[1], EnsureProdboxIdentityConfigMap)
                assert isinstance(built_effect.effects[2], AnnotateProdboxManagedResources)
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


class TestGatewayCommandPrerequisites:
    """Verify prerequisites and renderers for gateway commands."""

    def test_gateway_status_uses_query_node_and_rendered_output(self) -> None:
        """Gateway status should depend on the query node and render extended state."""
        cmd = GatewayStatusCommand(config_path=Path("/tmp/gateway.json"))
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("gateway_status")
                assert root is not None
                assert root.prerequisites == frozenset(["query_gateway_state"])
                assert isinstance(root.effect, WriteStdout)

                query = dag.get_node("query_gateway_state")
                assert query is not None
                assert query.prerequisites == frozenset()
                assert isinstance(query.effect, QueryGatewayState)

                built = root.build_effect(
                    None,
                    {
                        "query_gateway_state": Success(
                            {
                                "node_id": "node-a",
                                "gateway_owner": "node-a",
                                "has_active_claim": True,
                                "mesh_peers": ["node-b"],
                                "event_count": 5,
                                "last_public_ip_observed": "203.0.113.10",
                                "last_dns_write_ip": "203.0.113.10",
                                "last_dns_write_at_utc": "2026-04-06T10:00:00Z",
                                "dns_write_gate": {
                                    "zone_id": "Z123",
                                    "fqdn": "code.example.com",
                                    "ttl": 60,
                                },
                                "heartbeat_age_seconds": {
                                    "node-a": 0.0,
                                    "node-b": 1.5,
                                },
                            }
                        )
                    },
                )
                assert isinstance(built, WriteStdout)
                assert "ACTIVE_CLAIM=true" in built.text
                assert "DNS_WRITE_GATE=code.example.com@Z123 ttl=60" in built.text
                assert "HEARTBEAT_NODE_B=1.5" in built.text
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")

    def test_gateway_config_gen_has_no_prerequisites(self) -> None:
        """Gateway config generation should be a direct single-effect DAG."""
        cmd = GatewayConfigGenCommand(
            output_path=Path("/tmp/gateway.json"),
            node_id="node-a",
        )
        match command_to_dag(cmd):
            case Success(dag):
                root = dag.get_node("generate_gateway_config")
                assert root is not None
                assert root.prerequisites == frozenset()
                assert isinstance(root.effect, GenerateGatewayConfig)
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestUserVisibleCommandBuilderRegressionGuards:
    """Regression guards for repaired user-facing command builders."""

    @pytest.mark.parametrize(
        ("command", "root_id"),
        [
            (HostCheckPortsCommand(ports=(80, 443)), "host_check_ports"),
            (HostPublicEdgeCommand(), "host_public_edge"),
            (DNSCheckCommand(), "dns_check"),
            (GatewayStatusCommand(config_path=Path("/tmp/gateway.json")), "gateway_status"),
            (
                GatewayConfigGenCommand(output_path=Path("/tmp/gateway.json"), node_id="node-a"),
                "generate_gateway_config",
            ),
            (PulumiPreviewCommand(stack="dev"), "pulumi_preview"),
            (PulumiUpCommand(stack="dev", yes=False), "pulumi_up"),
            (PulumiDestroyCommand(stack="dev", yes=True), "pulumi_destroy"),
            (PulumiRefreshCommand(stack="dev"), "pulumi_refresh"),
            (PulumiStackInitCommand(stack="dev"), "pulumi_stack_init"),
        ],
    )
    def test_repaired_commands_do_not_regress_to_lone_pure_root(
        self,
        command: object,
        root_id: str,
    ) -> None:
        """Repaired user-facing commands must not collapse back to a lone Pure root."""
        match command_to_dag(command):
            case Success(dag):
                root = dag.get_node(root_id)
                assert root is not None
                assert not (
                    len(dag) == 1 and isinstance(root.effect, Pure)
                ), f"{root_id} regressed to a lone Pure root"
            case Failure(error):
                pytest.fail(f"Expected Success, got Failure: {error}")


class TestAllPrerequisitesExistInRegistry:
    """Verify all referenced prerequisites exist in the registry."""

    def test_all_host_prerequisites_exist(self) -> None:
        """All prerequisites referenced by host commands should exist."""
        commands = [
            HostInfoCommand(),
            HostCheckPortsCommand(),
            HostEnsureToolsCommand(),
            HostFirewallCommand(),
            HostPublicEdgeCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert dag.get_node(prereq_id) is not None, (
                                f"Prerequisite '{prereq_id}' not expanded into DAG "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")

    def test_all_gateway_prerequisites_exist(self) -> None:
        """All prerequisites referenced by gateway commands should exist."""
        commands = [
            GatewayStartCommand(config_path=Path("/tmp/gateway.json")),
            GatewayStatusCommand(config_path=Path("/tmp/gateway.json")),
            GatewayConfigGenCommand(output_path=Path("/tmp/gateway.json"), node_id="node-a"),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert dag.get_node(prereq_id) is not None, (
                                f"Prerequisite '{prereq_id}' not expanded into DAG "
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
            RKE2InstallCommand(),
            RKE2DeleteCommand(),
            RKE2LogsCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert dag.get_node(prereq_id) is not None, (
                                f"Prerequisite '{prereq_id}' not expanded into DAG "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")

    def test_all_dns_prerequisites_exist(self) -> None:
        """All prerequisites referenced by DNS commands should exist."""
        commands = [
            DNSCheckCommand(),
        ]
        for cmd in commands:
            match command_to_dag(cmd):
                case Success(dag):
                    for node in dag.nodes:
                        for prereq_id in node.prerequisites:
                            assert dag.get_node(prereq_id) is not None, (
                                f"Prerequisite '{prereq_id}' not expanded into DAG "
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
                            assert dag.get_node(prereq_id) is not None, (
                                f"Prerequisite '{prereq_id}' not expanded into DAG "
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
                            assert dag.get_node(prereq_id) is not None, (
                                f"Prerequisite '{prereq_id}' not expanded into DAG "
                                f"(referenced by '{node.effect_id}')"
                            )
                case Failure(error):
                    pytest.fail(f"Expected Success, got Failure: {error}")
