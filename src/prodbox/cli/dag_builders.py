"""DAG builders for converting Command ADTs to Effect DAGs.

This module provides functions that convert Command ADTs into Effect DAGs
using exhaustive pattern matching. This separation enables:

1. Pure transformation: Command -> Effect DAG (no side effects)
2. Single source of truth for command->DAG mapping
3. Testable: DAG structure can be verified without execution
4. Type-safe: Pattern matching ensures all commands handled

Architecture:
    Command (ADT) -> command_to_dag() -> EffectDAG -> Interpreter

Usage:
    from prodbox.cli.dag_builders import command_to_dag

    match command_to_dag(my_command):
        case Success(dag):
            result = interpreter.execute_dag(dag)
        case Failure(error):
            return error  # Propagate error up to command entry point
"""

from __future__ import annotations

from pathlib import Path

from prodbox.cli.command_adt import (
    Command,
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
)
from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import (
    CaptureKubectlOutput,
    CaptureSubprocessOutput,
    CheckFileExists,
    CheckServiceStatus,
    FetchPublicIP,
    GenerateGatewayConfig,
    GetJournalLogs,
    KubectlWait,
    PulumiDestroy,
    PulumiPreview,
    PulumiRefresh,
    PulumiUp,
    Pure,
    QueryGatewayState,
    RunKubectlCommand,
    RunPulumiCommand,
    RunSystemdCommand,
    StartGatewayDaemon,
    ValidateSettings,
    ValidateTool,
)
from prodbox.cli.prerequisite_registry import PREREQUISITE_REGISTRY
from prodbox.cli.types import Result, Success

# =============================================================================
# Environment Command Builders
# =============================================================================


def _build_env_show_dag(_cmd: EnvShowCommand) -> EffectDAG:
    """Build DAG for showing environment configuration."""
    root = EffectNode(
        effect=ValidateSettings(
            effect_id="env_show",
            description="Show environment configuration",
        ),
        prerequisites=frozenset(["settings_loaded"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_env_validate_dag(_cmd: EnvValidateCommand) -> EffectDAG:
    """Build DAG for validating environment configuration."""
    root = EffectNode(
        effect=ValidateSettings(
            effect_id="env_validate",
            description="Validate environment configuration",
        ),
        prerequisites=frozenset(["settings_loaded"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_env_template_dag(cmd: EnvTemplateCommand) -> EffectDAG:
    """Build DAG for generating environment template."""
    root = EffectNode(
        effect=Pure(
            effect_id="env_template",
            description="Generate environment template",
            value=str(cmd.output_path),
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Host Command Builders
# =============================================================================


def _build_host_info_dag(_cmd: HostInfoCommand) -> EffectDAG:
    """Build DAG for showing host information."""
    root = EffectNode(
        effect=CaptureSubprocessOutput(
            effect_id="host_info",
            description="Get host system information",
            command=["uname", "-a"],
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_host_check_ports_dag(cmd: HostCheckPortsCommand) -> EffectDAG:
    """Build DAG for checking port availability."""
    root = EffectNode(
        effect=Pure(
            effect_id="host_check_ports",
            description=f"Check ports: {cmd.ports}",
            value=cmd.ports,
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_host_ensure_tools_dag(_cmd: HostEnsureToolsCommand) -> EffectDAG:
    """Build DAG for checking required CLI tools."""
    root = EffectNode(
        effect=ValidateTool(
            effect_id="host_ensure_tools",
            description="Check required CLI tools",
            tool_name="kubectl",
        ),
        prerequisites=frozenset(["tool_kubectl", "tool_helm", "tool_pulumi"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_host_firewall_dag(_cmd: HostFirewallCommand) -> EffectDAG:
    """Build DAG for checking firewall status."""
    root = EffectNode(
        effect=CaptureSubprocessOutput(
            effect_id="host_firewall",
            description="Check firewall status",
            command=["ufw", "status"],
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# RKE2 Command Builders
# =============================================================================


def _build_rke2_status_dag(_cmd: RKE2StatusCommand) -> EffectDAG:
    """Build DAG for RKE2 status check."""
    root = EffectNode(
        effect=CheckServiceStatus(
            effect_id="rke2_status",
            description="Check RKE2 service status",
            service="rke2-server.service",
        ),
        prerequisites=frozenset(["platform_linux", "rke2_installed"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_start_dag(_cmd: RKE2StartCommand) -> EffectDAG:
    """Build DAG for starting RKE2."""
    root = EffectNode(
        effect=RunSystemdCommand(
            effect_id="rke2_start",
            description="Start RKE2 service",
            action="start",
            service="rke2-server.service",
            sudo=True,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_stop_dag(_cmd: RKE2StopCommand) -> EffectDAG:
    """Build DAG for stopping RKE2."""
    root = EffectNode(
        effect=RunSystemdCommand(
            effect_id="rke2_stop",
            description="Stop RKE2 service",
            action="stop",
            service="rke2-server.service",
            sudo=True,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_restart_dag(_cmd: RKE2RestartCommand) -> EffectDAG:
    """Build DAG for restarting RKE2."""
    root = EffectNode(
        effect=RunSystemdCommand(
            effect_id="rke2_restart",
            description="Restart RKE2 service",
            action="restart",
            service="rke2-server.service",
            sudo=True,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_ensure_dag(_cmd: RKE2EnsureCommand) -> EffectDAG:
    """Build DAG for ensuring RKE2 is installed."""
    root = EffectNode(
        effect=CheckFileExists(
            effect_id="rke2_ensure",
            description="Ensure RKE2 is installed",
            file_path=Path("/usr/local/bin/rke2"),
        ),
        prerequisites=frozenset(["platform_linux"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_logs_dag(cmd: RKE2LogsCommand) -> EffectDAG:
    """Build DAG for showing RKE2 logs."""
    root = EffectNode(
        effect=GetJournalLogs(
            effect_id="rke2_logs",
            description=f"Get RKE2 logs (last {cmd.lines} lines)",
            service="rke2-server.service",
            lines=cmd.lines,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# DNS Command Builders
# =============================================================================


def _build_dns_check_dag(_cmd: DNSCheckCommand) -> EffectDAG:
    """Build DAG for DNS status check."""
    # This will need to be expanded to get settings and query Route53
    root = EffectNode(
        effect=FetchPublicIP(
            effect_id="dns_check",
            description="Check DNS status and public IP",
        ),
        prerequisites=frozenset(["settings_loaded", "aws_credentials_valid"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_dns_update_dag(_cmd: DNSUpdateCommand) -> EffectDAG:
    """Build DAG for DNS update."""
    root = EffectNode(
        effect=FetchPublicIP(
            effect_id="dns_update",
            description="Update DNS record with public IP",
        ),
        prerequisites=frozenset(["settings_loaded", "route53_accessible"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_dns_ensure_timer_dag(cmd: DNSEnsureTimerCommand) -> EffectDAG:
    """Build DAG for installing DDNS timer."""
    root = EffectNode(
        effect=RunSystemdCommand(
            effect_id="dns_ensure_timer",
            description=f"Install DDNS timer (interval: {cmd.interval}min)",
            action="enable",
            service="route53-ddns.timer",
            sudo=True,
        ),
        prerequisites=frozenset(["settings_loaded", "systemd_available"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Kubernetes Command Builders
# =============================================================================


def _build_k8s_health_dag(_cmd: K8sHealthCommand) -> EffectDAG:
    """Build DAG for Kubernetes health check."""
    root = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id="k8s_health",
            description="Check Kubernetes cluster health",
            args=["cluster-info"],
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_k8s_wait_dag(cmd: K8sWaitCommand) -> EffectDAG:
    """Build DAG for waiting on Kubernetes deployments."""
    root = EffectNode(
        effect=KubectlWait(
            effect_id="k8s_wait",
            description=f"Wait for deployments (timeout: {cmd.timeout}s)",
            resource="deployment",
            condition="available",
            all_resources=True,
            timeout=cmd.timeout,
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_k8s_logs_dag(cmd: K8sLogsCommand) -> EffectDAG:
    """Build DAG for getting Kubernetes logs."""
    root = EffectNode(
        effect=RunKubectlCommand(
            effect_id="k8s_logs",
            description="Get infrastructure pod logs",
            args=["logs", "--all-containers=true", f"--tail={cmd.tail}"],
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Pulumi Command Builders
# =============================================================================


def _build_pulumi_preview_dag(cmd: PulumiPreviewCommand) -> EffectDAG:
    """Build DAG for Pulumi preview."""
    root = EffectNode(
        effect=PulumiPreview(
            effect_id="pulumi_preview",
            description="Preview infrastructure changes",
            cwd=cmd.cwd,
            stack=cmd.stack,
        ),
        prerequisites=frozenset(["tool_pulumi", "pulumi_logged_in"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_pulumi_up_dag(cmd: PulumiUpCommand) -> EffectDAG:
    """Build DAG for Pulumi up."""
    root = EffectNode(
        effect=PulumiUp(
            effect_id="pulumi_up",
            description="Apply infrastructure changes",
            cwd=cmd.cwd,
            stack=cmd.stack,
            yes=cmd.yes,
        ),
        prerequisites=frozenset(["tool_pulumi", "pulumi_stack_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_pulumi_destroy_dag(cmd: PulumiDestroyCommand) -> EffectDAG:
    """Build DAG for Pulumi destroy."""
    root = EffectNode(
        effect=PulumiDestroy(
            effect_id="pulumi_destroy",
            description="Destroy infrastructure",
            cwd=cmd.cwd,
            stack=cmd.stack,
            yes=cmd.yes,
        ),
        prerequisites=frozenset(["tool_pulumi", "pulumi_stack_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_pulumi_refresh_dag(cmd: PulumiRefreshCommand) -> EffectDAG:
    """Build DAG for Pulumi refresh."""
    root = EffectNode(
        effect=PulumiRefresh(
            effect_id="pulumi_refresh",
            description="Refresh infrastructure state",
            cwd=cmd.cwd,
            stack=cmd.stack,
        ),
        prerequisites=frozenset(["tool_pulumi", "pulumi_stack_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_pulumi_stack_init_dag(cmd: PulumiStackInitCommand) -> EffectDAG:
    """Build DAG for Pulumi stack init."""
    root = EffectNode(
        effect=RunPulumiCommand(
            effect_id="pulumi_stack_init",
            description=f"Initialize Pulumi stack '{cmd.stack}'",
            args=["stack", "init", cmd.stack],
            cwd=cmd.cwd,
        ),
        prerequisites=frozenset(["tool_pulumi", "pulumi_logged_in"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Main Entry Point
# =============================================================================


def command_to_dag(command: Command) -> Result[EffectDAG, str]:
    """Convert a Command ADT to an Effect DAG.

    Uses exhaustive pattern matching to ensure all command types are handled.

    Args:
        command: The Command ADT to convert

    Returns:
        Success with EffectDAG if conversion succeeds, Failure otherwise
    """
    match command:
        # Environment commands
        case EnvShowCommand():
            return Success(_build_env_show_dag(command))
        case EnvValidateCommand():
            return Success(_build_env_validate_dag(command))
        case EnvTemplateCommand():
            return Success(_build_env_template_dag(command))

        # Host commands
        case HostInfoCommand():
            return Success(_build_host_info_dag(command))
        case HostCheckPortsCommand():
            return Success(_build_host_check_ports_dag(command))
        case HostEnsureToolsCommand():
            return Success(_build_host_ensure_tools_dag(command))
        case HostFirewallCommand():
            return Success(_build_host_firewall_dag(command))

        # RKE2 commands
        case RKE2StatusCommand():
            return Success(_build_rke2_status_dag(command))
        case RKE2StartCommand():
            return Success(_build_rke2_start_dag(command))
        case RKE2StopCommand():
            return Success(_build_rke2_stop_dag(command))
        case RKE2RestartCommand():
            return Success(_build_rke2_restart_dag(command))
        case RKE2EnsureCommand():
            return Success(_build_rke2_ensure_dag(command))
        case RKE2LogsCommand():
            return Success(_build_rke2_logs_dag(command))

        # DNS commands
        case DNSCheckCommand():
            return Success(_build_dns_check_dag(command))
        case DNSUpdateCommand():
            return Success(_build_dns_update_dag(command))
        case DNSEnsureTimerCommand():
            return Success(_build_dns_ensure_timer_dag(command))

        # Kubernetes commands
        case K8sHealthCommand():
            return Success(_build_k8s_health_dag(command))
        case K8sWaitCommand():
            return Success(_build_k8s_wait_dag(command))
        case K8sLogsCommand():
            return Success(_build_k8s_logs_dag(command))

        # Pulumi commands
        case PulumiPreviewCommand():
            return Success(_build_pulumi_preview_dag(command))
        case PulumiUpCommand():
            return Success(_build_pulumi_up_dag(command))
        case PulumiDestroyCommand():
            return Success(_build_pulumi_destroy_dag(command))
        case PulumiRefreshCommand():
            return Success(_build_pulumi_refresh_dag(command))
        case PulumiStackInitCommand():
            return Success(_build_pulumi_stack_init_dag(command))

        # Gateway commands
        case GatewayStartCommand():
            return Success(_build_gateway_start_dag(command))
        case GatewayStatusCommand():
            return Success(_build_gateway_status_dag(command))
        case GatewayConfigGenCommand():
            return Success(_build_gateway_config_gen_dag(command))

    # This should never be reached if all cases are handled
    # mypy will catch missing cases at type-check time


# =============================================================================
# Gateway Command Builders
# =============================================================================


def _build_gateway_start_dag(cmd: GatewayStartCommand) -> EffectDAG:
    """Build DAG for starting gateway daemon."""
    root = EffectNode(
        effect=StartGatewayDaemon(
            effect_id="start_gateway_daemon",
            description="Start gateway daemon",
            config_path=cmd.config_path,
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_gateway_status_dag(cmd: GatewayStatusCommand) -> EffectDAG:
    """Build DAG for querying gateway daemon state."""
    root = EffectNode(
        effect=QueryGatewayState(
            effect_id="query_gateway_state",
            description="Query gateway daemon state",
            config_path=cmd.config_path,
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_gateway_config_gen_dag(cmd: GatewayConfigGenCommand) -> EffectDAG:
    """Build DAG for generating gateway config template."""
    root = EffectNode(
        effect=GenerateGatewayConfig(
            effect_id="generate_gateway_config",
            description="Generate gateway config template",
            output_path=cmd.output_path,
            node_id=cmd.node_id,
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    "command_to_dag",
]
