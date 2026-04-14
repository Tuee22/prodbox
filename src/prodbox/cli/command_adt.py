"""Command ADTs for type-safe CLI commands.

This module defines commands as immutable ADTs (frozen dataclasses) with
smart constructors that validate at construction time. This pattern enables:

1. Type-safe command representation
2. Validation at construction (fail-fast)
3. Platform-aware smart constructors (Linux-only commands fail on other platforms)
4. Exhaustive pattern matching on command variants
5. Single entry point for command execution

Architecture:
    Command (ADT) -> validate via smart constructor -> execute_command()

Usage:
    from prodbox.cli.command_adt import (
        DNSCheckCommand,
        dns_check_command,
        execute_command,
        Command,
    )

    # Smart constructor validates and returns Result
    match dns_check_command():
        case Success(cmd):
            await execute_command(cmd)
        case Failure(error):
            return error  # Propagate error up to command entry point
"""

from __future__ import annotations

import platform
from dataclasses import dataclass
from pathlib import Path

from prodbox.cli.types import Failure, Result, Success

# =============================================================================
# Config Commands
# =============================================================================


@dataclass(frozen=True)
class ConfigInitCommand:
    """Bootstrap Dhall config from existing .env and system state."""


@dataclass(frozen=True)
class ConfigCompileCommand:
    """Compile prodbox-config.dhall to prodbox-config.json via dhall-to-json."""


@dataclass(frozen=True)
class ConfigShowCommand:
    """Show configuration from compiled JSON.

    Attributes:
        show_secrets: Whether to show secret values (default: masked)
    """

    show_secrets: bool = False


@dataclass(frozen=True)
class ConfigValidateCommand:
    """Validate compiled JSON configuration."""


# =============================================================================
# Host Commands
# =============================================================================


@dataclass(frozen=True)
class HostInfoCommand:
    """Show host system information."""


@dataclass(frozen=True)
class HostCheckPortsCommand:
    """Check if required ports are available.

    Attributes:
        ports: Ports to check
    """

    ports: tuple[int, ...] = (80, 443)


@dataclass(frozen=True)
class HostEnsureToolsCommand:
    """Check that required CLI tools are installed."""


@dataclass(frozen=True)
class HostFirewallCommand:
    """Check and display firewall status."""


@dataclass(frozen=True)
class HostPublicEdgeCommand:
    """Diagnose the canonical public-edge path for the VS Code host."""


# =============================================================================
# RKE2 Commands
# =============================================================================


@dataclass(frozen=True)
class RKE2StatusCommand:
    """Check RKE2 installation and service status."""


@dataclass(frozen=True)
class RKE2StartCommand:
    """Start RKE2 server service."""


@dataclass(frozen=True)
class RKE2StopCommand:
    """Stop RKE2 server service."""


@dataclass(frozen=True)
class RKE2RestartCommand:
    """Restart RKE2 server service."""


@dataclass(frozen=True)
class RKE2InstallCommand:
    """Install or reconcile the supported host-owned RKE2 cluster lifecycle."""


@dataclass(frozen=True)
class RKE2DeleteCommand:
    """Delete the supported host-owned RKE2 cluster while preserving the manual PV root."""


@dataclass(frozen=True)
class RKE2LogsCommand:
    """Show recent RKE2 server logs.

    Attributes:
        lines: Number of log lines to show
    """

    lines: int = 50


# =============================================================================
# DNS Commands
# =============================================================================


@dataclass(frozen=True)
class DNSCheckCommand:
    """Check current DNS record and public IP."""


# =============================================================================
# Kubernetes Commands
# =============================================================================


@dataclass(frozen=True)
class K8sHealthCommand:
    """Check health of Kubernetes cluster and components."""


@dataclass(frozen=True)
class K8sWaitCommand:
    """Wait for deployments to be ready.

    Attributes:
        timeout: Timeout in seconds
        namespaces: Namespaces to wait for
    """

    timeout: int = 300
    namespaces: tuple[str, ...] = ("metallb-system", "traefik-system", "cert-manager")


@dataclass(frozen=True)
class K8sLogsCommand:
    """Show recent logs from infrastructure pods.

    Attributes:
        namespaces: Namespaces to get logs from
        tail: Number of log lines per container
    """

    namespaces: tuple[str, ...] = ("metallb-system", "traefik-system", "cert-manager")
    tail: int = 10


# =============================================================================
# Pulumi Commands
# =============================================================================


@dataclass(frozen=True)
class PulumiPreviewCommand:
    """Preview infrastructure changes.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
    """

    stack: str | None = None
    cwd: Path | None = None


@dataclass(frozen=True)
class PulumiUpCommand:
    """Apply infrastructure changes.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt
    """

    stack: str | None = None
    cwd: Path | None = None
    yes: bool = True


@dataclass(frozen=True)
class PulumiDestroyCommand:
    """Destroy infrastructure.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt
    """

    stack: str | None = None
    cwd: Path | None = None
    yes: bool = False


@dataclass(frozen=True)
class PulumiRefreshCommand:
    """Refresh infrastructure state.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
    """

    stack: str | None = None
    cwd: Path | None = None


@dataclass(frozen=True)
class PulumiStackInitCommand:
    """Initialize a new Pulumi stack.

    Attributes:
        stack: Stack name to create
        cwd: Working directory for Pulumi
    """

    stack: str
    cwd: Path | None = None


@dataclass(frozen=True)
class PulumiTestResourcesCommand:
    """Provision or inspect the canonical Pulumi-managed AWS test stack."""


@dataclass(frozen=True)
class PulumiTestDestroyCommand:
    """Destroy the canonical Pulumi-managed AWS test stack."""


# =============================================================================
# Gateway Commands
# =============================================================================


@dataclass(frozen=True)
class GatewayStartCommand:
    """Start gateway daemon from config file.

    Attributes:
        config_path: Path to gateway daemon JSON config file
    """

    config_path: Path


@dataclass(frozen=True)
class GatewayStatusCommand:
    """Query running gateway daemon status.

    Attributes:
        config_path: Path to gateway daemon JSON config file (for endpoint info)
    """

    config_path: Path


@dataclass(frozen=True)
class GatewayConfigGenCommand:
    """Generate template gateway config file.

    Attributes:
        output_path: Path to write template config
        node_id: Node ID for the generated config
    """

    output_path: Path
    node_id: str


# =============================================================================
# Chart Platform Commands
# =============================================================================


@dataclass(frozen=True)
class ChartListCommand:
    """List all supported charts with install status."""


@dataclass(frozen=True)
class ChartStatusCommand:
    """Show one-chart detailed status.

    Attributes:
        chart_name: Name of the chart to inspect
    """

    chart_name: str


@dataclass(frozen=True)
class ChartDeployCommand:
    """Deploy root chart + all prerequisites into root namespace.

    Attributes:
        chart_name: Name of the root chart to deploy
    """

    chart_name: str


@dataclass(frozen=True)
class ChartDeleteCommand:
    """Delete root chart stack (preserve .data).

    Attributes:
        chart_name: Name of the root chart stack to delete
        yes: Skip confirmation prompt
    """

    chart_name: str
    yes: bool = False


# =============================================================================
# Command Union Type
# =============================================================================

Command = (
    # Config
    ConfigInitCommand
    | ConfigCompileCommand
    | ConfigShowCommand
    | ConfigValidateCommand
    # Host
    | HostInfoCommand
    | HostCheckPortsCommand
    | HostEnsureToolsCommand
    | HostFirewallCommand
    | HostPublicEdgeCommand
    # RKE2
    | RKE2StatusCommand
    | RKE2StartCommand
    | RKE2StopCommand
    | RKE2RestartCommand
    | RKE2InstallCommand
    | RKE2DeleteCommand
    | RKE2LogsCommand
    # DNS
    | DNSCheckCommand
    # Kubernetes
    | K8sHealthCommand
    | K8sWaitCommand
    | K8sLogsCommand
    # Pulumi
    | PulumiPreviewCommand
    | PulumiUpCommand
    | PulumiDestroyCommand
    | PulumiRefreshCommand
    | PulumiStackInitCommand
    | PulumiTestResourcesCommand
    | PulumiTestDestroyCommand
    # Gateway
    | GatewayStartCommand
    | GatewayStatusCommand
    | GatewayConfigGenCommand
    # Chart platform
    | ChartListCommand
    | ChartStatusCommand
    | ChartDeployCommand
    | ChartDeleteCommand
)


# =============================================================================
# Smart Constructors
# =============================================================================


def config_init_command() -> Result[ConfigInitCommand, str]:
    """Create a ConfigInitCommand."""
    return Success(ConfigInitCommand())


def config_compile_command() -> Result[ConfigCompileCommand, str]:
    """Create a ConfigCompileCommand."""
    return Success(ConfigCompileCommand())


def config_show_command(*, show_secrets: bool = False) -> Result[ConfigShowCommand, str]:
    """Create a ConfigShowCommand."""
    return Success(ConfigShowCommand(show_secrets=show_secrets))


def config_validate_command() -> Result[ConfigValidateCommand, str]:
    """Create a ConfigValidateCommand."""
    return Success(ConfigValidateCommand())


def host_info_command() -> Result[HostInfoCommand, str]:
    """Create a HostInfoCommand.

    Returns:
        Success with HostInfoCommand
    """
    return Success(HostInfoCommand())


def host_check_ports_command(
    *,
    ports: list[int] | None = None,
) -> Result[HostCheckPortsCommand, str]:
    """Create a HostCheckPortsCommand.

    Args:
        ports: List of ports to check

    Returns:
        Success with HostCheckPortsCommand, Failure if invalid ports
    """
    port_list = ports or [80, 443]

    # Validate port numbers
    invalid = [p for p in port_list if p < 1 or p > 65535]
    if invalid:
        return Failure(f"Invalid port numbers: {invalid}. Must be 1-65535")

    return Success(HostCheckPortsCommand(ports=tuple(port_list)))


def host_ensure_tools_command() -> Result[HostEnsureToolsCommand, str]:
    """Create a HostEnsureToolsCommand.

    Returns:
        Success with HostEnsureToolsCommand
    """
    return Success(HostEnsureToolsCommand())


def host_firewall_command() -> Result[HostFirewallCommand, str]:
    """Create a HostFirewallCommand.

    Returns:
        Success with HostFirewallCommand
    """
    return Success(HostFirewallCommand())


def host_public_edge_command() -> Result[HostPublicEdgeCommand, str]:
    """Create a HostPublicEdgeCommand."""
    return Success(HostPublicEdgeCommand())


def rke2_status_command() -> Result[RKE2StatusCommand, str]:
    """Create an RKE2StatusCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2StatusCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2StatusCommand())


def rke2_start_command() -> Result[RKE2StartCommand, str]:
    """Create an RKE2StartCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2StartCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2StartCommand())


def rke2_stop_command() -> Result[RKE2StopCommand, str]:
    """Create an RKE2StopCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2StopCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2StopCommand())


def rke2_restart_command() -> Result[RKE2RestartCommand, str]:
    """Create an RKE2RestartCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2RestartCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2RestartCommand())


def rke2_install_command() -> Result[RKE2InstallCommand, str]:
    """Create an RKE2InstallCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2InstallCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2InstallCommand())


def rke2_delete_command(*, yes: bool = False) -> Result[RKE2DeleteCommand, str]:
    """Create an RKE2DeleteCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.
    SAFETY: Requires explicit --yes acknowledgement because delete is destructive.

    Args:
        yes: Confirmation flag from CLI --yes option

    Returns:
        Success with RKE2DeleteCommand on Linux when yes=True, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    if not yes:
        return Failure("rke2 delete requires --yes confirmation")

    return Success(RKE2DeleteCommand())


def rke2_logs_command(
    *,
    lines: int = 50,
) -> Result[RKE2LogsCommand, str]:
    """Create an RKE2LogsCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Args:
        lines: Number of log lines to show

    Returns:
        Success with RKE2LogsCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    if lines < 1:
        return Failure("Lines must be at least 1")

    return Success(RKE2LogsCommand(lines=lines))


def dns_check_command() -> Result[DNSCheckCommand, str]:
    """Create a DNSCheckCommand.

    Returns:
        Success with DNSCheckCommand
    """
    return Success(DNSCheckCommand())


def k8s_health_command() -> Result[K8sHealthCommand, str]:
    """Create a K8sHealthCommand.

    Returns:
        Success with K8sHealthCommand
    """
    return Success(K8sHealthCommand())


def k8s_wait_command(
    *,
    timeout: int = 300,
    namespaces: list[str] | None = None,
) -> Result[K8sWaitCommand, str]:
    """Create a K8sWaitCommand.

    Args:
        timeout: Timeout in seconds
        namespaces: Namespaces to wait for

    Returns:
        Success with K8sWaitCommand, Failure if invalid args
    """
    if timeout < 1:
        return Failure("Timeout must be at least 1 second")

    ns = tuple(namespaces) if namespaces else ("metallb-system", "traefik-system", "cert-manager")

    return Success(K8sWaitCommand(timeout=timeout, namespaces=ns))


def k8s_logs_command(
    *,
    namespaces: list[str] | None = None,
    tail: int = 10,
) -> Result[K8sLogsCommand, str]:
    """Create a K8sLogsCommand.

    Args:
        namespaces: Namespaces to get logs from
        tail: Number of log lines per container

    Returns:
        Success with K8sLogsCommand, Failure if invalid args
    """
    if tail < 1:
        return Failure("Tail must be at least 1")

    ns = tuple(namespaces) if namespaces else ("metallb-system", "traefik-system", "cert-manager")

    return Success(K8sLogsCommand(namespaces=ns, tail=tail))


def pulumi_preview_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
) -> Result[PulumiPreviewCommand, str]:
    """Create a PulumiPreviewCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi

    Returns:
        Success with PulumiPreviewCommand
    """
    return Success(PulumiPreviewCommand(stack=stack, cwd=cwd))


def pulumi_up_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
    yes: bool = True,
) -> Result[PulumiUpCommand, str]:
    """Create a PulumiUpCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt

    Returns:
        Success with PulumiUpCommand
    """
    return Success(PulumiUpCommand(stack=stack, cwd=cwd, yes=yes))


def pulumi_destroy_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
    yes: bool = False,
) -> Result[PulumiDestroyCommand, str]:
    """Create a PulumiDestroyCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt

    Returns:
        Success with PulumiDestroyCommand
    """
    return Success(PulumiDestroyCommand(stack=stack, cwd=cwd, yes=yes))


def pulumi_refresh_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
) -> Result[PulumiRefreshCommand, str]:
    """Create a PulumiRefreshCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi

    Returns:
        Success with PulumiRefreshCommand
    """
    return Success(PulumiRefreshCommand(stack=stack, cwd=cwd))


def pulumi_stack_init_command(
    stack: str,
    *,
    cwd: Path | None = None,
) -> Result[PulumiStackInitCommand, str]:
    """Create a PulumiStackInitCommand.

    Args:
        stack: Stack name to create
        cwd: Working directory for Pulumi

    Returns:
        Success with PulumiStackInitCommand, Failure if invalid stack name
    """
    if not stack or not stack.strip():
        return Failure("Stack name is required")

    # Validate stack name format (alphanumeric, hyphens, underscores)
    import re

    if not re.match(r"^[a-zA-Z0-9_-]+$", stack):
        return Failure(
            f"Invalid stack name: {stack}. Must contain only alphanumeric characters, "
            "hyphens, and underscores"
        )

    return Success(PulumiStackInitCommand(stack=stack, cwd=cwd))


def pulumi_test_resources_command() -> Result[PulumiTestResourcesCommand, str]:
    """Create a PulumiTestResourcesCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with PulumiTestResourcesCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("Pulumi AWS test-stack commands require Linux")

    return Success(PulumiTestResourcesCommand())


def pulumi_test_destroy_command(*, yes: bool = False) -> Result[PulumiTestDestroyCommand, str]:
    """Create a PulumiTestDestroyCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.
    SAFETY: Requires explicit --yes acknowledgement because destroy is destructive.

    Args:
        yes: Confirmation flag from CLI --yes option

    Returns:
        Success with PulumiTestDestroyCommand on Linux when yes=True, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("Pulumi AWS test-stack commands require Linux")

    if not yes:
        return Failure("pulumi test-destroy requires --yes confirmation")

    return Success(PulumiTestDestroyCommand())


# =============================================================================
# Utility Functions
# =============================================================================


def gateway_start_command(
    *,
    config_path: Path,
) -> Result[GatewayStartCommand, str]:
    """Create a GatewayStartCommand.

    Args:
        config_path: Path to gateway daemon config file

    Returns:
        Success with GatewayStartCommand, Failure if config file missing
    """
    if not config_path.exists():
        return Failure(f"Gateway config file not found: {config_path}")

    return Success(GatewayStartCommand(config_path=config_path))


def gateway_status_command(
    *,
    config_path: Path,
) -> Result[GatewayStatusCommand, str]:
    """Create a GatewayStatusCommand.

    Args:
        config_path: Path to gateway daemon config file

    Returns:
        Success with GatewayStatusCommand, Failure if config file missing
    """
    if not config_path.exists():
        return Failure(f"Gateway config file not found: {config_path}")

    return Success(GatewayStatusCommand(config_path=config_path))


def gateway_config_gen_command(
    *,
    output_path: Path,
    node_id: str,
) -> Result[GatewayConfigGenCommand, str]:
    """Create a GatewayConfigGenCommand.

    Args:
        output_path: Path to write template config
        node_id: Node ID for the generated config

    Returns:
        Success with GatewayConfigGenCommand, Failure if invalid args
    """
    if not node_id or not node_id.strip():
        return Failure("Node ID is required")

    return Success(GatewayConfigGenCommand(output_path=output_path, node_id=node_id))


def chart_list_command() -> Result[ChartListCommand, str]:
    """Create a ChartListCommand.

    Returns:
        Success with ChartListCommand
    """
    return Success(ChartListCommand())


def chart_status_command(chart_name: str) -> Result[ChartStatusCommand, str]:
    """Create a ChartStatusCommand, validating the chart name.

    Args:
        chart_name: Name of the chart to inspect

    Returns:
        Success with ChartStatusCommand, Failure if chart_name not supported
    """
    from prodbox.lib.chart_platform import supported_chart_names

    if chart_name not in supported_chart_names():
        supported = ", ".join(supported_chart_names())
        return Failure(f"Unsupported chart '{chart_name}'. Supported charts: {supported}")
    return Success(ChartStatusCommand(chart_name=chart_name))


def chart_deploy_command(chart_name: str) -> Result[ChartDeployCommand, str]:
    """Create a ChartDeployCommand, validating the chart name.

    Args:
        chart_name: Name of the root chart to deploy

    Returns:
        Success with ChartDeployCommand, Failure if chart_name not supported
    """
    from prodbox.lib.chart_platform import supported_chart_names

    if chart_name not in supported_chart_names():
        supported = ", ".join(supported_chart_names())
        return Failure(f"Unsupported chart '{chart_name}'. Supported charts: {supported}")
    return Success(ChartDeployCommand(chart_name=chart_name))


def chart_delete_command(chart_name: str, *, yes: bool = False) -> Result[ChartDeleteCommand, str]:
    """Create a ChartDeleteCommand, validating the chart name.

    Args:
        chart_name: Name of the root chart stack to delete
        yes: Skip confirmation prompt

    Returns:
        Success with ChartDeleteCommand, Failure if chart_name not supported
    """
    from prodbox.lib.chart_platform import supported_chart_names

    if chart_name not in supported_chart_names():
        supported = ", ".join(supported_chart_names())
        return Failure(f"Unsupported chart '{chart_name}'. Supported charts: {supported}")
    return Success(ChartDeleteCommand(chart_name=chart_name, yes=yes))


def is_linux() -> bool:
    """Check if running on Linux.

    Returns:
        True if on Linux, False otherwise
    """
    return platform.system() == "Linux"


def requires_linux(command: Command) -> bool:
    """Check if a command requires Linux.

    Args:
        command: Command to check

    Returns:
        True if the command can only run on Linux
    """
    match command:
        # RKE2 commands require Linux (systemd)
        case RKE2StatusCommand() | RKE2StartCommand() | RKE2StopCommand():
            return True
        case RKE2RestartCommand() | RKE2InstallCommand() | RKE2DeleteCommand() | RKE2LogsCommand():
            return True
        # Config commands - cross-platform
        case (
            ConfigInitCommand()
            | ConfigCompileCommand()
            | ConfigShowCommand()
            | ConfigValidateCommand()
        ):
            return False
        # Host commands - cross-platform (will fail gracefully on non-Linux)
        case (
            HostInfoCommand()
            | HostCheckPortsCommand()
            | HostEnsureToolsCommand()
            | HostFirewallCommand()
        ):
            return False
        case HostPublicEdgeCommand():
            return False
        # DNS check - cross-platform (AWS API)
        case DNSCheckCommand():
            return False
        # Kubernetes commands - cross-platform
        case K8sHealthCommand() | K8sWaitCommand() | K8sLogsCommand():
            return False
        # Pulumi commands - cross-platform
        case PulumiPreviewCommand() | PulumiUpCommand() | PulumiDestroyCommand():
            return False
        case PulumiRefreshCommand() | PulumiStackInitCommand():
            return False
        case PulumiTestResourcesCommand() | PulumiTestDestroyCommand():
            return True
        # Gateway commands - cross-platform
        case GatewayStartCommand() | GatewayStatusCommand() | GatewayConfigGenCommand():
            return False
        # Chart commands - cross-platform
        case (
            ChartListCommand()
            | ChartStatusCommand()
            | ChartDeployCommand()
            | ChartDeleteCommand()
        ):
            return False


def requires_settings(command: Command) -> bool:
    """Check if a command requires settings to be loaded.

    Args:
        command: Command to check

    Returns:
        True if the command requires prodbox settings
    """
    match command:
        # DNS commands require AWS settings
        case DNSCheckCommand():
            return True
        # Kubernetes commands require kubeconfig path
        case K8sHealthCommand() | K8sWaitCommand() | K8sLogsCommand():
            return True
        # Pulumi commands require stack and AWS settings
        case PulumiPreviewCommand() | PulumiUpCommand() | PulumiDestroyCommand():
            return True
        case PulumiRefreshCommand() | PulumiStackInitCommand():
            return True
        case PulumiTestResourcesCommand() | PulumiTestDestroyCommand():
            return True
        # Config commands - show/validate need settings, init/compile do not
        case ConfigShowCommand() | ConfigValidateCommand():
            return True
        case ConfigInitCommand() | ConfigCompileCommand():
            return False
        # Host commands don't require settings
        case (
            HostInfoCommand()
            | HostCheckPortsCommand()
            | HostEnsureToolsCommand()
            | HostFirewallCommand()
        ):
            return False
        case HostPublicEdgeCommand():
            return True
        # RKE2 inspection/service commands use system paths; install/delete read settings.
        case RKE2StatusCommand() | RKE2StartCommand() | RKE2StopCommand() | RKE2RestartCommand():
            return False
        case RKE2InstallCommand() | RKE2DeleteCommand():
            return True
        case RKE2LogsCommand():
            return False
        # Gateway commands don't require prodbox settings (use own config file)
        case GatewayStartCommand() | GatewayStatusCommand() | GatewayConfigGenCommand():
            return False
        # Chart commands require settings (FQDN, credentials, kubeconfig)
        case (
            ChartListCommand()
            | ChartStatusCommand()
            | ChartDeployCommand()
            | ChartDeleteCommand()
        ):
            return True


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    # Command types
    "Command",
    # Config
    "ConfigInitCommand",
    "ConfigCompileCommand",
    "ConfigShowCommand",
    "ConfigValidateCommand",
    # Host
    "HostInfoCommand",
    "HostCheckPortsCommand",
    "HostEnsureToolsCommand",
    "HostFirewallCommand",
    "HostPublicEdgeCommand",
    # RKE2
    "RKE2StatusCommand",
    "RKE2StartCommand",
    "RKE2StopCommand",
    "RKE2RestartCommand",
    "RKE2InstallCommand",
    "RKE2DeleteCommand",
    "RKE2LogsCommand",
    # DNS
    "DNSCheckCommand",
    # Kubernetes
    "K8sHealthCommand",
    "K8sWaitCommand",
    "K8sLogsCommand",
    # Pulumi
    "PulumiPreviewCommand",
    "PulumiUpCommand",
    "PulumiDestroyCommand",
    "PulumiRefreshCommand",
    "PulumiStackInitCommand",
    "PulumiTestResourcesCommand",
    "PulumiTestDestroyCommand",
    # Gateway
    "GatewayStartCommand",
    "GatewayStatusCommand",
    "GatewayConfigGenCommand",
    # Chart platform
    "ChartListCommand",
    "ChartStatusCommand",
    "ChartDeployCommand",
    "ChartDeleteCommand",
    # Smart constructors
    "config_init_command",
    "config_compile_command",
    "config_show_command",
    "config_validate_command",
    "host_info_command",
    "host_check_ports_command",
    "host_ensure_tools_command",
    "host_firewall_command",
    "host_public_edge_command",
    "rke2_status_command",
    "rke2_start_command",
    "rke2_stop_command",
    "rke2_restart_command",
    "rke2_install_command",
    "rke2_delete_command",
    "rke2_logs_command",
    "dns_check_command",
    "k8s_health_command",
    "k8s_wait_command",
    "k8s_logs_command",
    "pulumi_preview_command",
    "pulumi_up_command",
    "pulumi_destroy_command",
    "pulumi_refresh_command",
    "pulumi_stack_init_command",
    "pulumi_test_resources_command",
    "pulumi_test_destroy_command",
    "gateway_start_command",
    "gateway_status_command",
    "gateway_config_gen_command",
    # Chart smart constructors
    "chart_list_command",
    "chart_status_command",
    "chart_deploy_command",
    "chart_delete_command",
    # Utility functions
    "is_linux",
    "requires_linux",
    "requires_settings",
]
